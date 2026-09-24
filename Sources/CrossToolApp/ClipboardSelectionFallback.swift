import AppKit
@preconcurrency import ApplicationServices
import Carbon.HIToolbox
import Foundation

enum ClipboardSelectionFallbackResult: Equatable, Sendable {
    case selected(String)
    case noSelection
    case eventPermissionRequired
    case secureInput
    case preservationUnavailable
    case targetChanged
    case restoreFailed
    case busy
    case cancelled
    case unavailable
}

enum SecureInputState: Equatable, Sendable {
    case secure
    case notSecure
    case unknown
}

struct ClipboardSelectionFallbackConfiguration: Equatable, Sendable {
    var initialDelayNanoseconds: UInt64
    var pollingIntervalNanoseconds: UInt64
    var stableIntervalNanoseconds: UInt64
    var timeoutNanoseconds: UInt64
    var maximumSnapshotBytes: Int
    var maximumItemCount: Int
    var maximumTypesPerItem: Int
    var snapshotAttempts: Int

    init(
        initialDelayNanoseconds: UInt64 = 30_000_000,
        pollingIntervalNanoseconds: UInt64 = 12_000_000,
        stableIntervalNanoseconds: UInt64 = 36_000_000,
        timeoutNanoseconds: UInt64 = 700_000_000,
        maximumSnapshotBytes: Int = 64 * 1_024 * 1_024,
        maximumItemCount: Int = 128,
        maximumTypesPerItem: Int = 128,
        snapshotAttempts: Int = 2
    ) {
        self.initialDelayNanoseconds = initialDelayNanoseconds
        self.pollingIntervalNanoseconds = pollingIntervalNanoseconds
        self.stableIntervalNanoseconds = stableIntervalNanoseconds
        self.timeoutNanoseconds = timeoutNanoseconds
        self.maximumSnapshotBytes = maximumSnapshotBytes
        self.maximumItemCount = maximumItemCount
        self.maximumTypesPerItem = maximumTypesPerItem
        self.snapshotAttempts = snapshotAttempts
    }
}

/// Compatibility reader for applications that do not expose selected text via
/// Accessibility. The caller must try the Accessibility path first.
///
/// A fallback operation is deliberately single-flight. It temporarily asks the
/// foreground application to copy its selection, reads only a newly produced
/// pasteboard value, and restores a byte-for-byte snapshot when it still owns
/// that value. If another process changes the pasteboard, its newer contents
/// win and are never overwritten.
@MainActor
final class ClipboardSelectionFallback {
    typealias FrontmostApplicationPIDProvider = @MainActor @Sendable () -> pid_t?
    typealias EventAccessChecker = @MainActor @Sendable () -> Bool
    typealias SecureInputChecker = @MainActor @Sendable (pid_t) -> Bool
    typealias CopyEventPoster = @MainActor @Sendable (pid_t) -> Bool
    typealias TimeProvider = @MainActor @Sendable () -> UInt64
    /// Must not terminate early solely because the surrounding task was
    /// cancelled. After posting Copy, cleanup owns a bounded settlement window.
    typealias Sleeper = @MainActor @Sendable (UInt64) async -> Void
    typealias TextReader = @MainActor @Sendable () -> String?

    private let pasteboard: NSPasteboard
    private let configuration: ClipboardSelectionFallbackConfiguration
    private let frontmostApplicationPID: FrontmostApplicationPIDProvider
    private let eventAccessChecker: EventAccessChecker
    private let secureInputChecker: SecureInputChecker
    private let copyEventPoster: CopyEventPoster
    private let timeProvider: TimeProvider
    private let sleeper: Sleeper
    private let textReader: TextReader
    private let clipboardHistoryObservationGate: ClipboardHistoryObservationGate?
    private var activeOperationID: UUID?

    init(
        pasteboard: NSPasteboard = .general,
        configuration: ClipboardSelectionFallbackConfiguration = .init(),
        frontmostApplicationPID: @escaping FrontmostApplicationPIDProvider = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        },
        eventAccessChecker: @escaping EventAccessChecker = {
            CGPreflightPostEventAccess()
        },
        secureInputChecker: @escaping SecureInputChecker = { applicationPID in
            ClipboardSelectionFallback.secureInputState(
                applicationPID: applicationPID
            ) != .notSecure
        },
        copyEventPoster: @escaping CopyEventPoster = { applicationPID in
            ClipboardSelectionFallback.postCommandC(applicationPID: applicationPID)
        },
        timeProvider: @escaping TimeProvider = {
            DispatchTime.now().uptimeNanoseconds
        },
        sleeper: @escaping Sleeper = { nanoseconds in
            await ClipboardSelectionFallback.sleepIgnoringCancellation(
                nanoseconds: nanoseconds
            )
        },
        textReader: TextReader? = nil,
        clipboardHistoryObservationGate: ClipboardHistoryObservationGate? = nil
    ) {
        self.pasteboard = pasteboard
        self.configuration = configuration
        self.frontmostApplicationPID = frontmostApplicationPID
        self.eventAccessChecker = eventAccessChecker
        self.secureInputChecker = secureInputChecker
        self.copyEventPoster = copyEventPoster
        self.timeProvider = timeProvider
        self.sleeper = sleeper
        self.clipboardHistoryObservationGate = clipboardHistoryObservationGate
        self.textReader = textReader ?? {
            pasteboard.string(forType: .string)
        }
    }

    func capture(applicationPID: pid_t) async -> ClipboardSelectionFallbackResult {
        guard activeOperationID == nil else { return .busy }
        let operationID = UUID()
        activeOperationID = operationID
        defer {
            if activeOperationID == operationID {
                activeOperationID = nil
            }
        }

        guard eventAccessChecker() else { return .eventPermissionRequired }
        guard frontmostApplicationPID() == applicationPID else { return .targetChanged }
        guard !secureInputChecker(applicationPID) else { return .secureInput }

        guard let snapshot = makeStableSnapshot() else {
            return .preservationUnavailable
        }
        let transaction = PasteboardRestoreTransaction(
            pasteboard: pasteboard,
            snapshot: snapshot
        )
        var observationLease: ClipboardHistoryObservationGate.Lease?
        var mayReceiveDelayedWrite = false
        defer {
            transaction.restoreIfNeeded()
            if let observationLease {
                clipboardHistoryObservationGate?.finishSuppression(
                    observationLease,
                    settledChangeCount: pasteboard.changeCount,
                    mayReceiveDelayedWrite: mayReceiveDelayedWrite
                )
            }
        }

        if configuration.initialDelayNanoseconds > 0 {
            await sleeper(configuration.initialDelayNanoseconds)
        }
        guard !Task.isCancelled else { return .cancelled }
        guard frontmostApplicationPID() == applicationPID else { return .targetChanged }
        guard !secureInputChecker(applicationPID) else { return .secureInput }
        guard pasteboard.changeCount == snapshot.changeCount else {
            return .preservationUnavailable
        }
        observationLease = clipboardHistoryObservationGate?.beginSuppression()
        guard copyEventPoster(applicationPID) else { return .unavailable }
        mayReceiveDelayedWrite = true

        let startedAt = timeProvider()
        var observedChangeCount: Int?
        var stableSince: UInt64?
        var cancellationRequested = false
        var targetChangedAfterPosting = false

        while elapsed(since: startedAt, now: timeProvider()) < configuration.timeoutNanoseconds {
            cancellationRequested = cancellationRequested || Task.isCancelled
            targetChangedAfterPosting = targetChangedAfterPosting
                || frontmostApplicationPID() != applicationPID

            let currentChangeCount = pasteboard.changeCount
            if currentChangeCount != snapshot.changeCount,
               currentChangeCount != observedChangeCount,
               observedChangeCount != nil {
                // There is no public pasteboard API that identifies the writer.
                // Once a second owner change appears, treating it as ours could
                // overwrite a newer user copy. Preserve the latest contents and
                // fail closed instead.
                transaction.abandon()
                return .preservationUnavailable
            }
            if currentChangeCount != snapshot.changeCount,
               observedChangeCount == nil {
                observedChangeCount = currentChangeCount
                mayReceiveDelayedWrite = false
                stableSince = timeProvider()
                transaction.claim(changeCount: currentChangeCount)
            }

            if let observedChangeCount,
               let stableSince,
                   elapsed(since: stableSince, now: timeProvider())
                   >= configuration.stableIntervalNanoseconds {
                guard pasteboard.changeCount == observedChangeCount else {
                    transaction.abandon()
                    return .preservationUnavailable
                }
                if cancellationRequested {
                    return .cancelled
                }
                if targetChangedAfterPosting {
                    // The first pasteboard change can no longer be attributed
                    // safely to our targeted Copy. Preserve the newer value.
                    transaction.abandon()
                    return .targetChanged
                }
                guard !secureInputChecker(applicationPID) else {
                    return .secureInput
                }
                let text = textReader()
                let restoration = transaction.restoreIfNeeded()

                switch restoration {
                case .failed:
                    return .restoreFailed
                case .ownershipLost:
                    return .preservationUnavailable
                case .notNeeded, .restored:
                    break
                }

                return normalized(text).map(ClipboardSelectionFallbackResult.selected)
                    ?? .noSelection
            }

            await sleeper(max(configuration.pollingIntervalNanoseconds, 1))
        }

        if cancellationRequested || Task.isCancelled { return .cancelled }
        if targetChangedAfterPosting {
            transaction.abandon()
            return .targetChanged
        }
        return .noSelection
    }

    private func makeStableSnapshot() -> PasteboardSnapshot? {
        let attempts = max(configuration.snapshotAttempts, 1)
        for _ in 0 ..< attempts {
            let initialChangeCount = pasteboard.changeCount
            guard isPasteboardAccessAllowed else { return nil }
            guard let snapshot = PasteboardSnapshot.capture(
                from: pasteboard,
                changeCount: initialChangeCount,
                configuration: configuration
            ) else {
                return nil
            }
            if pasteboard.changeCount == initialChangeCount {
                return snapshot
            }
        }
        return nil
    }

    private var isPasteboardAccessAllowed: Bool {
        if #available(macOS 15.4, *) {
            return pasteboard.accessBehavior != .alwaysDeny
        }
        return true
    }

    private func normalized(_ text: String?) -> String? {
        guard let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }

    private func elapsed(since start: UInt64, now: UInt64) -> UInt64 {
        guard now >= start else { return 0 }
        return now - start
    }

    private static func postCommandC(applicationPID: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_C),
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_C),
                  keyDown: false
              ) else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(applicationPID)
        keyUp.postToPid(applicationPID)
        return true
    }

    private static func sleepIgnoringCancellation(nanoseconds: UInt64) async {
        guard nanoseconds > 0 else {
            await Task.yield()
            return
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .nanoseconds(Int(clamping: nanoseconds))
            ) {
                continuation.resume()
            }
        }
    }

    static func isSecureInputActive(applicationPID: pid_t) -> Bool {
        secureInputState(applicationPID: applicationPID) != .notSecure
    }

    static func secureInputState(applicationPID: pid_t) -> SecureInputState {
        if IsSecureEventInputEnabled() {
            return .secure
        }

        let application = AXUIElementCreateApplication(applicationPID)
        AXUIElementSetMessagingTimeout(application, 0.1)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return .unknown
        }

        let focusedElement = unsafeBitCast(focusedValue, to: AXUIElement.self)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        var secureFieldFound = false
        var securityStateBecameUnknown = false
        var reachedApplication = false

        let termination = AccessibilityAncestorWalker.walk(
            from: focusedElement,
            shouldContinue: {
                ProcessInfo.processInfo.systemUptime < deadline
            },
            isSameNode: { CFEqual($0, $1) },
            visit: { element in
                AXUIElementSetMessagingTimeout(element, 0.1)
                var subroleValue: CFTypeRef?
                let subroleError = AXUIElementCopyAttributeValue(
                    element,
                    kAXSubroleAttribute as CFString,
                    &subroleValue
                )
                if subroleError == .success {
                    guard let subrole = subroleValue as? String else {
                        securityStateBecameUnknown = true
                        return .stop
                    }
                    if subrole == (kAXSecureTextFieldSubrole as String) {
                        secureFieldFound = true
                        return .stop
                    }
                } else if subroleError != .noValue,
                          subroleError != .attributeUnsupported {
                    securityStateBecameUnknown = true
                    return .stop
                }
                if CFEqual(element, application) {
                    reachedApplication = true
                    return .stop
                }
                return .continueTraversal
            },
            parent: { element in
                var parentValue: CFTypeRef?
                let parentError = AXUIElementCopyAttributeValue(
                    element,
                    kAXParentAttribute as CFString,
                    &parentValue
                )
                if parentError == .noValue || parentError == .attributeUnsupported {
                    securityStateBecameUnknown = true
                    return nil
                }
                guard parentError == .success,
                      let parentValue,
                      CFGetTypeID(parentValue) == AXUIElementGetTypeID() else {
                    securityStateBecameUnknown = true
                    return nil
                }
                return unsafeBitCast(parentValue, to: AXUIElement.self)
            }
        )

        if secureFieldFound || securityStateBecameUnknown {
            return secureFieldFound ? .secure : .unknown
        }
        switch termination {
        case .stopped where reachedApplication:
            return .notSecure
        case .stopped, .exhausted, .cycleDetected, .interrupted:
            return .unknown
        }
    }

}

private struct PasteboardSnapshot {
    struct Representation {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    struct Item {
        let representations: [Representation]
    }

    let changeCount: Int
    let items: [Item]

    static func capture(
        from pasteboard: NSPasteboard,
        changeCount: Int,
        configuration: ClipboardSelectionFallbackConfiguration
    ) -> PasteboardSnapshot? {
        // An empty pasteboard is reported as an empty array. `nil` means the
        // server could not provide the items (for example, access was denied),
        // so treating it as empty would risk destroying contents we could not
        // snapshot.
        guard let sourceItems = pasteboard.pasteboardItems else { return nil }
        guard sourceItems.count <= max(configuration.maximumItemCount, 0) else {
            return nil
        }

        let maximumSnapshotBytes = max(configuration.maximumSnapshotBytes, 0)
        var byteCount = 0
        var items: [Item] = []
        items.reserveCapacity(sourceItems.count)

        for sourceItem in sourceItems {
            let types = sourceItem.types
            guard !types.isEmpty,
                  types.count <= max(configuration.maximumTypesPerItem, 0) else {
                return nil
            }

            var representations: [Representation] = []
            representations.reserveCapacity(types.count)
            for type in types {
                guard let sourceData = sourceItem.data(forType: type) else {
                    return nil
                }
                guard sourceData.count <= maximumSnapshotBytes,
                      byteCount <= maximumSnapshotBytes - sourceData.count else {
                    return nil
                }
                byteCount += sourceData.count
                representations.append(
                    Representation(type: type, data: Data(sourceData))
                )
            }
            items.append(Item(representations: representations))
        }

        return PasteboardSnapshot(changeCount: changeCount, items: items)
    }

    func makePasteboardItems() -> [NSPasteboardItem]? {
        var restoredItems: [NSPasteboardItem] = []
        restoredItems.reserveCapacity(items.count)

        for item in items {
            let restoredItem = NSPasteboardItem()
            for representation in item.representations {
                guard restoredItem.setData(
                    representation.data,
                    forType: representation.type
                ) else {
                    return nil
                }
            }
            restoredItems.append(restoredItem)
        }
        return restoredItems
    }
}

@MainActor
private final class PasteboardRestoreTransaction {
    enum Restoration {
        case notNeeded
        case restored
        case ownershipLost
        case failed
    }

    private let pasteboard: NSPasteboard
    private let snapshot: PasteboardSnapshot
    private var ownedChangeCount: Int?
    private var isFinished = false

    init(pasteboard: NSPasteboard, snapshot: PasteboardSnapshot) {
        self.pasteboard = pasteboard
        self.snapshot = snapshot
    }

    func claim(changeCount: Int) {
        guard !isFinished else { return }
        ownedChangeCount = changeCount
    }

    func abandon() {
        isFinished = true
        ownedChangeCount = nil
    }

    @discardableResult
    func restoreIfNeeded() -> Restoration {
        guard !isFinished else { return .notNeeded }
        guard let ownedChangeCount else {
            isFinished = true
            return .notNeeded
        }
        // Materialize every restored representation before the ownership
        // check. This keeps the unavoidable check-to-clear race as short as
        // the public NSPasteboard API permits.
        guard let restoredItems = snapshot.makePasteboardItems() else {
            isFinished = true
            return .failed
        }
        guard pasteboard.changeCount == ownedChangeCount else {
            isFinished = true
            return .ownershipLost
        }

        let clearedChangeCount = pasteboard.clearContents()
        if restoredItems.isEmpty {
            isFinished = true
            return .restored
        }
        guard pasteboard.changeCount == clearedChangeCount else {
            isFinished = true
            return .ownershipLost
        }
        if pasteboard.writeObjects(restoredItems) {
            isFinished = true
            return .restored
        }

        // A failed write normally changes ownership. Retry only when it left
        // the just-cleared pasteboard untouched; otherwise a newer writer wins.
        guard pasteboard.changeCount == clearedChangeCount else {
            isFinished = true
            return .ownershipLost
        }
        guard let retryItems = snapshot.makePasteboardItems(),
              pasteboard.changeCount == clearedChangeCount else {
            isFinished = true
            return .failed
        }

        let retryClearChangeCount = pasteboard.clearContents()
        guard pasteboard.changeCount == retryClearChangeCount else {
            isFinished = true
            return .ownershipLost
        }

        isFinished = true
        return pasteboard.writeObjects(retryItems) ? .restored : .failed
    }
}
