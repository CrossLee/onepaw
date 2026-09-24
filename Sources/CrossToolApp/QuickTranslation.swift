import AppKit
@preconcurrency import ApplicationServices
import Carbon.HIToolbox
import Foundation

enum QuickTranslationDirection: Equatable, Sendable {
    case chineseToEnglish
    case englishToChinese

    var sourceLanguageIdentifier: String {
        switch self {
        case .chineseToEnglish: return "zh-Hans"
        case .englishToChinese: return "en"
        }
    }

    var targetLanguageIdentifier: String {
        switch self {
        case .chineseToEnglish: return "en"
        case .englishToChinese: return "zh-Hans"
        }
    }
}

enum QuickTranslationDirectionResolver {
    static func direction(for text: String) -> QuickTranslationDirection? {
        var containsChinese = false
        var containsLatinLetter = false

        for scalar in text.unicodeScalars {
            if isHan(scalar.value) {
                containsChinese = true
                break
            }
            if isLatinLetter(scalar.value) {
                containsLatinLetter = true
            }
        }

        if containsChinese {
            return .chineseToEnglish
        }
        if containsLatinLetter {
            return .englishToChinese
        }
        return nil
    }

    private static func isHan(_ value: UInt32) -> Bool {
        switch value {
        case 0x3400 ... 0x4DBF,
             0x4E00 ... 0x9FFF,
             0xF900 ... 0xFAFF,
             0x20000 ... 0x2EBEF,
             0x30000 ... 0x323AF:
            return true
        default:
            return false
        }
    }

    private static func isLatinLetter(_ value: UInt32) -> Bool {
        switch value {
        case 0x0041 ... 0x005A,
             0x0061 ... 0x007A,
             0x00C0 ... 0x024F,
             0x1E00 ... 0x1EFF:
            return true
        default:
            return false
        }
    }
}

struct TextTranslationLaunchRequest: Identifiable, Equatable, Sendable {
    enum Payload: Equatable, Sendable {
        case translate(text: String, direction: QuickTranslationDirection)
        case message(String)
    }

    let id: UUID
    let payload: Payload

    init(id: UUID = UUID(), payload: Payload) {
        self.id = id
        self.payload = payload
    }
}

enum SelectedTextCaptureResult: Equatable, Sendable {
    case selected(String)
    case permissionRequired
    case noSelection
    case secureInput
    case clipboardUnavailable
    case clipboardRestoreFailed
    case targetChanged
    case cancelled
    case unavailable
}

/// Reads the current selection before OnePaw is activated. Accessibility is
/// preferred; applications that do not expose their selection can use a
/// guarded Copy fallback that restores the previous pasteboard contents.
@MainActor
struct SelectedTextCaptureService {
    typealias TrustChecker = @MainActor @Sendable () -> Bool
    typealias PermissionRequester = @MainActor @Sendable () -> Void
    typealias TargetValidator = @MainActor @Sendable (pid_t) -> Bool
    typealias SecureInputChecker = @MainActor @Sendable (pid_t) -> SecureInputState
    typealias SelectionReader = @Sendable (pid_t) -> SelectedTextCaptureResult
    typealias FallbackReader = @MainActor @Sendable (
        pid_t
    ) async -> ClipboardSelectionFallbackResult

    private let trustChecker: TrustChecker
    private let permissionRequester: PermissionRequester
    private let targetValidator: TargetValidator
    private let secureInputChecker: SecureInputChecker
    private let selectionReader: SelectionReader
    private let markerSelectionReader: SelectionReader
    private let fallbackReader: FallbackReader

    init(
        trustChecker: @escaping TrustChecker = { AXIsProcessTrusted() },
        permissionRequester: @escaping PermissionRequester = {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [promptKey: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        },
        targetValidator: @escaping TargetValidator = { applicationPID in
            NSWorkspace.shared.frontmostApplication?.processIdentifier == applicationPID
        },
        secureInputChecker: @escaping SecureInputChecker = { applicationPID in
            ClipboardSelectionFallback.secureInputState(
                applicationPID: applicationPID
            )
        },
        selectionReader: @escaping SelectionReader = { applicationPID in
            AXSelectedTextReader.read(applicationPID: applicationPID)
        },
        markerSelectionReader: @escaping SelectionReader = { applicationPID in
            AXTextMarkerSelectionReader.read(applicationPID: applicationPID)
        },
        clipboardHistoryObservationGate: ClipboardHistoryObservationGate? = nil,
        fallbackReader: FallbackReader? = nil
    ) {
        self.trustChecker = trustChecker
        self.permissionRequester = permissionRequester
        self.targetValidator = targetValidator
        self.secureInputChecker = secureInputChecker
        self.selectionReader = selectionReader
        self.markerSelectionReader = markerSelectionReader
        if let fallbackReader {
            self.fallbackReader = fallbackReader
        } else {
            let fallback = ClipboardSelectionFallback(
                clipboardHistoryObservationGate: clipboardHistoryObservationGate
            )
            self.fallbackReader = { applicationPID in
                await fallback.capture(applicationPID: applicationPID)
            }
        }
    }

    func capture(
        applicationPID: pid_t?,
        promptForPermission: Bool = true
    ) async -> SelectedTextCaptureResult {
        guard trustChecker() else {
            if promptForPermission {
                permissionRequester()
            }
            return .permissionRequired
        }
        guard let applicationPID else { return .unavailable }
        guard targetValidator(applicationPID) else { return .targetChanged }
        let initialSecurityState = secureInputChecker(applicationPID)
        if initialSecurityState == .secure { return .secureInput }
        guard targetValidator(applicationPID) else { return .targetChanged }

        if initialSecurityState == .unknown {
            return await captureUsingTextMarkers(applicationPID: applicationPID)
        }

        let selectionReader = self.selectionReader
        let readTask = Task.detached(priority: .userInitiated) {
            selectionReader(applicationPID)
        }
        let accessibilityResult = await withTaskCancellationHandler {
            await readTask.value
        } onCancel: {
            readTask.cancel()
        }

        guard !Task.isCancelled else { return .cancelled }
        guard targetValidator(applicationPID) else { return .targetChanged }
        if case .selected = accessibilityResult {
            switch secureInputChecker(applicationPID) {
            case .secure:
                return .secureInput
            case .unknown:
                return .unavailable
            case .notSecure:
                break
            }
        }
        guard targetValidator(applicationPID) else { return .targetChanged }

        switch accessibilityResult {
        case .selected, .permissionRequired, .secureInput,
             .clipboardUnavailable, .clipboardRestoreFailed,
             .targetChanged, .cancelled:
            return accessibilityResult
        case .noSelection, .unavailable:
            guard !Task.isCancelled else { return .cancelled }
            return await captureUsingClipboardFallback(applicationPID: applicationPID)
        }
    }

    private func captureUsingTextMarkers(
        applicationPID: pid_t
    ) async -> SelectedTextCaptureResult {
        let markerSelectionReader = self.markerSelectionReader
        let readTask = Task.detached(priority: .userInitiated) {
            markerSelectionReader(applicationPID)
        }
        let result = await withTaskCancellationHandler {
            await readTask.value
        } onCancel: {
            readTask.cancel()
        }

        guard !Task.isCancelled else { return .cancelled }
        guard targetValidator(applicationPID) else { return .targetChanged }
        // An unknown security state is never permitted to reach the synthetic
        // Copy path. The marker reader returns text only after validating both
        // range endpoints and their ancestor chains.
        switch result {
        case .selected, .noSelection, .secureInput, .cancelled:
            return result
        case .permissionRequired, .clipboardUnavailable,
             .clipboardRestoreFailed, .targetChanged, .unavailable:
            return .unavailable
        }
    }

    private func captureUsingClipboardFallback(
        applicationPID: pid_t
    ) async -> SelectedTextCaptureResult {
        switch await fallbackReader(applicationPID) {
        case .selected(let text):
            return .selected(text)
        case .noSelection:
            return .noSelection
        case .eventPermissionRequired:
            return .permissionRequired
        case .secureInput:
            return .secureInput
        case .preservationUnavailable:
            return .clipboardUnavailable
        case .restoreFailed:
            return .clipboardRestoreFailed
        case .targetChanged:
            return .targetChanged
        case .busy, .cancelled:
            return .cancelled
        case .unavailable:
            return .unavailable
        }
    }
}

enum AccessibilityAncestorVisitDecision {
    case continueTraversal
    case stop
}

enum AccessibilityAncestorWalkTermination: Equatable {
    case stopped
    case exhausted
    case cycleDetected
    case interrupted
}

enum AccessibilityAncestorWalker {
    static func walk<Node>(
        from initialNode: Node,
        shouldContinue: () -> Bool,
        isSameNode: (Node, Node) -> Bool,
        visit: (Node) -> AccessibilityAncestorVisitDecision,
        parent: (Node) -> Node?
    ) -> AccessibilityAncestorWalkTermination {
        var currentNode = initialNode
        var visitedNodes: [Node] = []

        while true {
            guard shouldContinue() else { return .interrupted }
            guard !visitedNodes.contains(where: { isSameNode($0, currentNode) }) else {
                return .cycleDetected
            }
            visitedNodes.append(currentNode)

            if visit(currentNode) == .stop {
                return .stopped
            }

            guard shouldContinue() else { return .interrupted }
            guard let parentNode = parent(currentNode) else { return .exhausted }
            currentNode = parentNode
        }
    }
}

enum AccessibilityDescendantVisitDecision {
    case continueTraversal
    case stop
    case fail
}

enum AccessibilityDescendantChildren<Node> {
    case children([Node])
    case fail
    case nodeLimitExceeded
}

enum AccessibilityDescendantWalkTermination: Equatable {
    case stopped
    case exhausted
    case failed
    case interrupted
    case nodeLimitExceeded
}

/// Breadth-first, cycle-safe traversal for accessibility subtrees. Exhaustion
/// is the only result that proves every reachable node inside the configured
/// bounds was visited successfully.
enum AccessibilityDescendantWalker {
    static func walk<Node>(
        from root: Node,
        maximumNodeCount: Int,
        shouldContinue: () -> Bool,
        isSameNode: (Node, Node) -> Bool,
        visit: (Node) -> AccessibilityDescendantVisitDecision,
        children: (Node) -> AccessibilityDescendantChildren<Node>
    ) -> AccessibilityDescendantWalkTermination {
        guard maximumNodeCount > 0 else { return .nodeLimitExceeded }

        var pending = [root]
        var nextIndex = 0
        var visited: [Node] = []
        visited.reserveCapacity(min(maximumNodeCount, 256))

        while nextIndex < pending.count {
            guard shouldContinue() else { return .interrupted }

            let node = pending[nextIndex]
            nextIndex += 1
            if visited.contains(where: { isSameNode($0, node) }) {
                continue
            }
            guard visited.count < maximumNodeCount else {
                return .nodeLimitExceeded
            }
            visited.append(node)

            switch visit(node) {
            case .stop:
                return .stopped
            case .fail:
                return .failed
            case .continueTraversal:
                break
            }

            switch children(node) {
            case .fail:
                return .failed
            case .nodeLimitExceeded:
                return .nodeLimitExceeded
            case .children(let childNodes):
                let queuedCount = pending.count - nextIndex
                guard childNodes.count <= maximumNodeCount - visited.count,
                      queuedCount <= maximumNodeCount - childNodes.count else {
                    return .nodeLimitExceeded
                }
                pending.append(contentsOf: childNodes)
            }
        }

        return .exhausted
    }
}

struct AccessibilityUniqueSelection<Value> {
    private(set) var value: Value?
    private(set) var isAmbiguous = false

    mutating func record(_ newValue: Value) -> Bool {
        guard value == nil, !isAmbiguous else {
            value = nil
            isAmbiguous = true
            return false
        }
        value = newValue
        return true
    }
}

enum AccessibilitySecurityChainValidator {
    static func state<Node>(
        from initialNode: Node,
        through requiredAncestor: Node,
        shouldContinue: () -> Bool,
        isSameNode: (Node, Node) -> Bool,
        inspect: (Node) -> SecureInputState,
        parent: (Node) -> Node?
    ) -> SecureInputState {
        var reachedRequiredAncestor = false
        var observedState = SecureInputState.notSecure
        let termination = AccessibilityAncestorWalker.walk(
            from: initialNode,
            shouldContinue: shouldContinue,
            isSameNode: isSameNode,
            visit: { node in
                let state = inspect(node)
                guard state == .notSecure else {
                    observedState = state
                    return .stop
                }
                if isSameNode(node, requiredAncestor) {
                    reachedRequiredAncestor = true
                    return .stop
                }
                return .continueTraversal
            },
            parent: parent
        )

        guard observedState == .notSecure else { return observedState }
        guard reachedRequiredAncestor,
              termination == .stopped else {
            return .unknown
        }
        return .notSecure
    }
}

private enum AXTextMarkerSelectionReader {
    private static let elementTimeout: Float = 0.1
    private static let overallTimeout: TimeInterval = 1.0
    private static let maximumNodeCount = 4_096
    private static let webAreaRole = "AXWebArea"

    static func read(applicationPID: pid_t) -> SelectedTextCaptureResult {
        guard !IsSecureEventInputEnabled() else { return .secureInput }
        let deadline = ProcessInfo.processInfo.systemUptime + overallTimeout
        let application = AXUIElementCreateApplication(applicationPID)
        AXUIElementSetMessagingTimeout(application, elementTimeout)

        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
        let windowValue,
        CFGetTypeID(windowValue) == AXUIElementGetTypeID() else {
            return .unavailable
        }
        let focusedWindow = unsafeBitCast(windowValue, to: AXUIElement.self)

        var terminalResult: SelectedTextCaptureResult?
        var foundMarkerCapability = false
        var selectedCandidates = AccessibilityUniqueSelection<(
            owner: AXUIElement,
            text: String
        )>()
        let termination = AccessibilityDescendantWalker.walk(
            from: focusedWindow,
            maximumNodeCount: maximumNodeCount,
            shouldContinue: {
                !isCancelled && ProcessInfo.processInfo.systemUptime < deadline
            },
            isSameNode: { CFEqual($0, $1) },
            visit: { element in
                switch markerCandidate(
                    from: element,
                    application: application,
                    focusedWindow: focusedWindow,
                    deadline: deadline
                ) {
                case .unsupported:
                    return .continueTraversal
                case .emptySelection:
                    foundMarkerCapability = true
                    return .continueTraversal
                case .selected(let text):
                    foundMarkerCapability = true
                    guard selectedCandidates.record((owner: element, text: text)) else {
                        // More than one non-empty marker selection is
                        // ambiguous. Never choose one by AX tree order.
                        terminalResult = .unavailable
                        return .stop
                    }
                    return .continueTraversal
                case .secureInput:
                    terminalResult = .secureInput
                    return .stop
                case .failed:
                    return .fail
                }
            },
            children: { children(of: $0, deadline: deadline) }
        )

        if let terminalResult { return terminalResult }
        switch termination {
        case .exhausted:
            guard focusedWindowIsCurrent(
                application: application,
                expected: focusedWindow,
                deadline: deadline
            ) else {
                return isCancelled ? .cancelled : .unavailable
            }
            guard let selectedCandidate = selectedCandidates.value else {
                return foundMarkerCapability ? .noSelection : .unavailable
            }

            // Re-read the sole candidate after the complete tree scan. This
            // rejects a selection or hierarchy that changed while traversing.
            switch markerCandidate(
                from: selectedCandidate.owner,
                application: application,
                focusedWindow: focusedWindow,
                deadline: deadline
            ) {
            case .selected(let text) where text == selectedCandidate.text:
                guard focusedWindowIsCurrent(
                    application: application,
                    expected: focusedWindow,
                    deadline: deadline
                ) else {
                    return isCancelled ? .cancelled : .unavailable
                }
                return .selected(text)
            case .secureInput:
                return .secureInput
            case .unsupported, .emptySelection, .selected, .failed:
                return .unavailable
            }
        case .interrupted where isCancelled:
            return .cancelled
        case .stopped, .failed, .interrupted, .nodeLimitExceeded:
            return .unavailable
        }
    }

    private enum MarkerCandidate {
        case unsupported
        case emptySelection
        case selected(String)
        case secureInput
        case failed
    }

    private static func markerCandidate(
        from element: AXUIElement,
        application: AXUIElement,
        focusedWindow: AXUIElement,
        deadline: TimeInterval
    ) -> MarkerCandidate {
        guard !isCancelled,
              ProcessInfo.processInfo.systemUptime < deadline else {
            return .failed
        }
        guard !IsSecureEventInputEnabled() else { return .secureInput }
        AXUIElementSetMessagingTimeout(element, elementTimeout)

        var roleValue: CFTypeRef?
        let roleError = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        )
        switch roleError {
        case .success:
            guard let role = roleValue as? String else { return .failed }
            guard role == webAreaRole else { return .unsupported }
        case .noValue, .attributeUnsupported:
            return .unsupported
        default:
            return .failed
        }

        var rangeValue: CFTypeRef?
        let rangeError = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextMarkerRangeAttribute as CFString,
            &rangeValue
        )
        if rangeError == .noValue { return .emptySelection }
        if rangeError == .attributeUnsupported { return .unsupported }
        guard rangeError == .success,
              let rangeValue else {
            return .failed
        }
        guard CFGetTypeID(rangeValue) == AXTextMarkerRangeGetTypeID() else {
            return .failed
        }
        let markerRange = unsafeBitCast(rangeValue, to: AXTextMarkerRange.self)

        switch validateEndpoints(
            of: markerRange,
            owner: element,
            focusedWindow: focusedWindow,
            application: application,
            deadline: deadline
        ) {
        case .secure:
            return .secureInput
        case .unknown:
            return .failed
        case .notSecure:
            break
        }

        guard !isCancelled,
              ProcessInfo.processInfo.systemUptime < deadline else {
            return .failed
        }
        var textValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForTextMarkerRangeParameterizedAttribute as CFString,
            rangeValue,
            &textValue
        ) == .success,
        let text = textValue as? String else {
            return .failed
        }
        guard !IsSecureEventInputEnabled() else { return .secureInput }
        switch validateEndpoints(
            of: markerRange,
            owner: element,
            focusedWindow: focusedWindow,
            application: application,
            deadline: deadline
        ) {
        case .secure:
            return .secureInput
        case .unknown:
            return .failed
        case .notSecure:
            break
        }
        guard focusedWindowIsCurrent(
            application: application,
            expected: focusedWindow,
            deadline: deadline
        ) else {
            return .failed
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .emptySelection : .selected(text)
    }

    private static func validateEndpoints(
        of range: AXTextMarkerRange,
        owner: AXUIElement,
        focusedWindow: AXUIElement,
        application: AXUIElement,
        deadline: TimeInterval
    ) -> SecureInputState {
        let startMarker = AXTextMarkerRangeCopyStartMarker(range)
        let endMarker = AXTextMarkerRangeCopyEndMarker(range)
        guard let startElement = element(for: startMarker, owner: owner),
              let endElement = element(for: endMarker, owner: owner) else {
            return .unknown
        }

        let startState = securityState(
            from: startElement,
            through: owner,
            deadline: deadline
        )
        guard startState == .notSecure else { return startState }
        let endState = securityState(
            from: endElement,
            through: owner,
            deadline: deadline
        )
        guard endState == .notSecure else { return endState }
        let ownerState = securityState(
            from: owner,
            through: focusedWindow,
            deadline: deadline
        )
        guard ownerState == .notSecure else { return ownerState }
        return securityState(
            from: focusedWindow,
            through: application,
            deadline: deadline
        )
    }

    private static func element(
        for marker: AXTextMarker,
        owner: AXUIElement
    ) -> AXUIElement? {
        var elementValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            owner,
            kAXUIElementForTextMarkerParameterizedAttribute as CFString,
            marker,
            &elementValue
        ) == .success,
        let elementValue,
        CFGetTypeID(elementValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(elementValue, to: AXUIElement.self)
    }

    private static func securityState(
        from endpoint: AXUIElement,
        through application: AXUIElement,
        deadline: TimeInterval
    ) -> SecureInputState {
        AccessibilitySecurityChainValidator.state(
            from: endpoint,
            through: application,
            shouldContinue: {
                !isCancelled && ProcessInfo.processInfo.systemUptime < deadline
            },
            isSameNode: { CFEqual($0, $1) },
            inspect: { element in
                AXUIElementSetMessagingTimeout(element, elementTimeout)
                var subroleValue: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(
                    element,
                    kAXSubroleAttribute as CFString,
                    &subroleValue
                )
                if error == .success {
                    guard let subrole = subroleValue as? String else { return .unknown }
                    if subrole == (kAXSecureTextFieldSubrole as String) {
                        return .secure
                    }
                } else if error != .noValue,
                          error != .attributeUnsupported {
                    return .unknown
                }
                return .notSecure
            },
            parent: { element in
                var parentValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    element,
                    kAXParentAttribute as CFString,
                    &parentValue
                ) == .success,
                let parentValue,
                CFGetTypeID(parentValue) == AXUIElementGetTypeID() else {
                    return nil
                }
                return unsafeBitCast(parentValue, to: AXUIElement.self)
            }
        )
    }

    private static func focusedWindowIsCurrent(
        application: AXUIElement,
        expected: AXUIElement,
        deadline: TimeInterval
    ) -> Bool {
        guard !isCancelled,
              ProcessInfo.processInfo.systemUptime < deadline else {
            return false
        }
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
        let windowValue,
        CFGetTypeID(windowValue) == AXUIElementGetTypeID() else {
            return false
        }
        let currentWindow = unsafeBitCast(windowValue, to: AXUIElement.self)
        return CFEqual(currentWindow, expected)
    }

    private static func children(
        of element: AXUIElement,
        deadline: TimeInterval
    ) -> AccessibilityDescendantChildren<AXUIElement> {
        guard !isCancelled,
              ProcessInfo.processInfo.systemUptime < deadline else {
            return .fail
        }
        AXUIElementSetMessagingTimeout(element, elementTimeout)
        var childCount: CFIndex = 0
        let countError = AXUIElementGetAttributeValueCount(
            element,
            kAXChildrenAttribute as CFString,
            &childCount
        )
        if countError == .noValue || countError == .attributeUnsupported {
            return .children([])
        }
        guard countError == .success,
              childCount >= 0 else {
            return .fail
        }
        guard childCount <= maximumNodeCount else {
            return .nodeLimitExceeded
        }
        guard childCount > 0 else { return .children([]) }
        guard !isCancelled,
              ProcessInfo.processInfo.systemUptime < deadline else {
            return .fail
        }

        var childrenValue: CFArray?
        guard AXUIElementCopyAttributeValues(
            element,
            kAXChildrenAttribute as CFString,
            0,
            childCount,
            &childrenValue
        ) == .success,
        let rawChildren = childrenValue as? [AnyObject],
        rawChildren.count <= maximumNodeCount else {
            return .fail
        }

        var children: [AXUIElement] = []
        children.reserveCapacity(rawChildren.count)
        for rawChild in rawChildren {
            guard !isCancelled,
                  ProcessInfo.processInfo.systemUptime < deadline else {
                return .fail
            }
            let childValue = rawChild as CFTypeRef
            guard CFGetTypeID(childValue) == AXUIElementGetTypeID() else {
                return .fail
            }
            children.append(unsafeBitCast(childValue, to: AXUIElement.self))
        }
        return .children(children)
    }

    private static var isCancelled: Bool {
        withUnsafeCurrentTask { $0?.isCancelled ?? false }
    }
}

private enum AXSelectedTextReader {
    private static let elementTimeout: Float = 0.2
    private static let overallTimeout: TimeInterval = 1.0

    private struct CandidateResult {
        let text: String?
        let supportsSelection: Bool
    }

    static func read(applicationPID: pid_t) -> SelectedTextCaptureResult {
        let deadline = ProcessInfo.processInfo.systemUptime + overallTimeout
        let applicationElement = AXUIElementCreateApplication(applicationPID)
        AXUIElementSetMessagingTimeout(applicationElement, elementTimeout)
        guard shouldContinue(before: deadline) else { return .unavailable }
        var focusedValue: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard focusedError == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return .unavailable
        }

        let focusedElement = unsafeBitCast(focusedValue, to: AXUIElement.self)
        var foundSelectionCapability = false
        var selectedText: String?

        let termination = AccessibilityAncestorWalker.walk(
            from: focusedElement,
            shouldContinue: { shouldContinue(before: deadline) },
            isSameNode: { CFEqual($0, $1) },
            visit: { currentElement in
                AXUIElementSetMessagingTimeout(currentElement, elementTimeout)
                let candidate = selectionCandidate(from: currentElement, deadline: deadline)
                foundSelectionCapability = foundSelectionCapability || candidate.supportsSelection
                if let text = candidate.text {
                    selectedText = text
                    return .stop
                }
                return .continueTraversal
            },
            parent: { currentElement in
                guard !CFEqual(currentElement, applicationElement) else { return nil }

                var parentValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    currentElement,
                    kAXParentAttribute as CFString,
                    &parentValue
                ) == .success,
                let parentValue,
                CFGetTypeID(parentValue) == AXUIElementGetTypeID() else {
                    return nil
                }
                return unsafeBitCast(parentValue, to: AXUIElement.self)
            }
        )

        if let selectedText {
            return .selected(selectedText)
        }
        if termination == .interrupted {
            return .unavailable
        }

        return foundSelectionCapability ? .noSelection : .unavailable
    }

    private static func selectionCandidate(
        from element: AXUIElement,
        deadline: TimeInterval
    ) -> CandidateResult {
        guard shouldContinue(before: deadline) else {
            return CandidateResult(text: nil, supportsSelection: false)
        }
        var value: CFTypeRef?
        let selectedTextError = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value
        )
        if selectedTextError == .success,
           let text = value as? String,
           let selectedText = nonemptySelection(text) {
            return CandidateResult(text: selectedText, supportsSelection: true)
        }
        let selectedTextSupported = selectedTextError == .success || selectedTextError == .noValue

        let rangeResult = selectedTextUsingRange(from: element, deadline: deadline)
        return CandidateResult(
            text: rangeResult.text,
            supportsSelection: selectedTextSupported || rangeResult.supportsSelection
        )
    }

    private static func shouldContinue(before deadline: TimeInterval) -> Bool {
        let isCancelled = withUnsafeCurrentTask { task in
            task?.isCancelled ?? false
        }
        return !isCancelled && ProcessInfo.processInfo.systemUptime < deadline
    }

    private static func selectedTextUsingRange(
        from element: AXUIElement,
        deadline: TimeInterval
    ) -> CandidateResult {
        guard shouldContinue(before: deadline) else {
            return CandidateResult(text: nil, supportsSelection: false)
        }
        var rangeValue: CFTypeRef?
        let rangeError = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        )
        guard rangeError == .success,
              let rangeValue,
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return CandidateResult(text: nil, supportsSelection: rangeError == .noValue)
        }

        var selectedRange = CFRange()
        let accessibilityRange = unsafeBitCast(rangeValue, to: AXValue.self)
        guard AXValueGetValue(accessibilityRange, .cfRange, &selectedRange),
              selectedRange.location != kCFNotFound,
              selectedRange.location >= 0 else {
            return CandidateResult(text: nil, supportsSelection: true)
        }
        guard selectedRange.length > 0 else {
            return CandidateResult(text: nil, supportsSelection: true)
        }

        guard shouldContinue(before: deadline) else {
            return CandidateResult(text: nil, supportsSelection: true)
        }
        var parameterizedText: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &parameterizedText
        ) == .success,
        let text = parameterizedText as? String {
            return CandidateResult(text: nonemptySelection(text), supportsSelection: true)
        }

        guard shouldContinue(before: deadline) else {
            return CandidateResult(text: nil, supportsSelection: true)
        }
        var textValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &textValue
        ) == .success,
        let fullText = textValue as? String else {
            return CandidateResult(text: nil, supportsSelection: true)
        }

        let string = fullText as NSString
        let range = NSRange(location: selectedRange.location, length: selectedRange.length)
        guard NSMaxRange(range) <= string.length else {
            return CandidateResult(text: nil, supportsSelection: true)
        }
        return CandidateResult(
            text: nonemptySelection(string.substring(with: range)),
            supportsSelection: true
        )
    }

    private static func nonemptySelection(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }
}
