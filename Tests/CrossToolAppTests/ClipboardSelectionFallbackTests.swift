import AppKit
import Foundation
import Testing
@testable import CrossToolApp

@MainActor
@Test func clipboardFallbackRestoresEveryItemTypeAndByte() async throws {
    let pasteboard = makeNamedPasteboard()
    defer { release(pasteboard) }

    let customType = NSPasteboard.PasteboardType("com.onepaw.tests.binary")
    let first = NSPasteboardItem()
    #expect(first.setString("原来的文字", forType: .string))
    #expect(first.setData(Data([0x00, 0x7F, 0xFF, 0x12]), forType: customType))

    let second = NSPasteboardItem()
    #expect(second.setData(Data("{\\rtf1 original}".utf8), forType: .rtf))
    #expect(second.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png))

    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([first, second]))
    let original = try pasteboardDump(pasteboard)

    let clock = TestClock()
    let fallback = makeFallback(
        pasteboard: pasteboard,
        clock: clock,
        copyEventPoster: { _ in
            pasteboard.clearContents()
            return pasteboard.setString("Hello from a custom editor.", forType: .string)
        }
    )

    let result = await fallback.capture(applicationPID: 4242)

    #expect(result == .selected("Hello from a custom editor."))
    #expect(try pasteboardDump(pasteboard) == original)
}

@MainActor
@Test func clipboardFallbackDoesNotReadStaleTextWhenCopyNeverChangesPasteboard() async throws {
    let pasteboard = makeNamedPasteboard()
    defer { release(pasteboard) }
    pasteboard.clearContents()
    #expect(pasteboard.setString("旧剪贴板文字，不能拿来翻译", forType: .string))
    let original = try pasteboardDump(pasteboard)
    let originalChangeCount = pasteboard.changeCount

    let probe = TestProbe()
    let clock = TestClock()
    let fallback = makeFallback(
        pasteboard: pasteboard,
        clock: clock,
        copyEventPoster: { _ in
            probe.eventPostCount += 1
            return true
        }
    )

    let result = await fallback.capture(applicationPID: 4242)

    #expect(result == .noSelection)
    #expect(probe.eventPostCount == 1)
    #expect(pasteboard.changeCount == originalChangeCount)
    #expect(try pasteboardDump(pasteboard) == original)
}

@MainActor
@Test func clipboardFallbackRestoresAnOriginallyEmptyPasteboard() async throws {
    let pasteboard = makeNamedPasteboard()
    defer { release(pasteboard) }
    #expect(pasteboard.pasteboardItems?.isEmpty == true)

    let clock = TestClock()
    let fallback = makeFallback(
        pasteboard: pasteboard,
        clock: clock,
        copyEventPoster: { _ in
            pasteboard.clearContents()
            return pasteboard.setString("selected", forType: .string)
        }
    )

    let result = await fallback.capture(applicationPID: 4242)

    #expect(result == .selected("selected"))
    #expect(pasteboard.pasteboardItems?.isEmpty == true)
}

@MainActor
@Test func clipboardFallbackDoesNotPostCopyDuringSecureInput() async throws {
    let pasteboard = makeNamedPasteboard()
    defer { release(pasteboard) }
    pasteboard.clearContents()
    #expect(pasteboard.setString("keep me", forType: .string))
    let original = try pasteboardDump(pasteboard)
    let originalChangeCount = pasteboard.changeCount

    let probe = TestProbe()
    let clock = TestClock()
    let fallback = makeFallback(
        pasteboard: pasteboard,
        clock: clock,
        secureInputChecker: { _ in true },
        copyEventPoster: { _ in
            probe.eventPostCount += 1
            pasteboard.clearContents()
            return pasteboard.setString("secret", forType: .string)
        }
    )

    let result = await fallback.capture(applicationPID: 4242)

    #expect(result == .secureInput)
    #expect(probe.eventPostCount == 0)
    #expect(pasteboard.changeCount == originalChangeCount)
    #expect(try pasteboardDump(pasteboard) == original)
}

@MainActor
@Test func clipboardFallbackDoesNotPostWithoutEventPermission() async throws {
    let pasteboard = makeNamedPasteboard()
    defer { release(pasteboard) }
    pasteboard.clearContents()
    #expect(pasteboard.setString("keep me", forType: .string))
    let original = try pasteboardDump(pasteboard)

    let probe = TestProbe()
    let fallback = ClipboardSelectionFallback(
        pasteboard: pasteboard,
        configuration: testConfiguration,
        frontmostApplicationPID: { 4242 },
        eventAccessChecker: { false },
        secureInputChecker: { _ in false },
        copyEventPoster: { _ in
            probe.eventPostCount += 1
            return true
        }
    )

    let result = await fallback.capture(applicationPID: 4242)

    #expect(result == .eventPermissionRequired)
    #expect(probe.eventPostCount == 0)
    #expect(try pasteboardDump(pasteboard) == original)
}

@MainActor
@Test func clipboardFallbackStopsWhenTargetChangesBeforeCopy() async throws {
    let pasteboard = makeNamedPasteboard()
    defer { release(pasteboard) }
    pasteboard.clearContents()
    #expect(pasteboard.setString("original", forType: .string))

    let probe = TestProbe()
    let clock = TestClock()
    var frontmostPID: pid_t = 4242
    var configuration = testConfiguration
    configuration.initialDelayNanoseconds = 10
    let fallback = ClipboardSelectionFallback(
        pasteboard: pasteboard,
        configuration: configuration,
        frontmostApplicationPID: { frontmostPID },
        eventAccessChecker: { true },
        secureInputChecker: { _ in false },
        copyEventPoster: { _ in
            probe.eventPostCount += 1
            return true
        },
        timeProvider: { clock.value },
        sleeper: { nanoseconds in
            frontmostPID = 9001
            await clock.sleep(nanoseconds)
        }
    )

    let result = await fallback.capture(applicationPID: 4242)

    #expect(result == .targetChanged)
    #expect(probe.eventPostCount == 0)
    #expect(pasteboard.string(forType: .string) == "original")
}

@MainActor
@Test func clipboardFallbackPreservesNewValueWhenTargetChangesAfterCopy() async throws {
    let pasteboard = makeNamedPasteboard()
    defer { release(pasteboard) }
    pasteboard.clearContents()
    #expect(pasteboard.setString("original", forType: .string))

    let clock = TestClock()
    var frontmostPID: pid_t = 4242
    let fallback = ClipboardSelectionFallback(
        pasteboard: pasteboard,
        configuration: testConfiguration,
        frontmostApplicationPID: { frontmostPID },
        eventAccessChecker: { true },
        secureInputChecker: { _ in false },
        copyEventPoster: { _ in
            pasteboard.clearContents()
            #expect(pasteboard.setString("must not be returned", forType: .string))
            frontmostPID = 9001
            return true
        },
        timeProvider: { clock.value },
        sleeper: { nanoseconds in
            await clock.sleep(nanoseconds)
        }
    )

    let result = await fallback.capture(applicationPID: 4242)

    #expect(result == .targetChanged)
    #expect(pasteboard.string(forType: .string) == "must not be returned")
}

@MainActor
@Test func clipboardFallbackFailsClosedWhenSnapshotIsTooLarge() async {
    let pasteboard = makeNamedPasteboard()
    defer { release(pasteboard) }
    pasteboard.clearContents()
    #expect(pasteboard.setString("larger than four bytes", forType: .string))

    let probe = TestProbe()
    var configuration = testConfiguration
    configuration.maximumSnapshotBytes = 4
    let fallback = ClipboardSelectionFallback(
        pasteboard: pasteboard,
        configuration: configuration,
        frontmostApplicationPID: { 4242 },
        eventAccessChecker: { true },
        secureInputChecker: { _ in false },
        copyEventPoster: { _ in
            probe.eventPostCount += 1
            return true
        }
    )

    let result = await fallback.capture(applicationPID: 4242)

    #expect(result == .preservationUnavailable)
    #expect(probe.eventPostCount == 0)
    #expect(pasteboard.string(forType: .string) == "larger than four bytes")
}

@MainActor
@Test func clipboardFallbackPreservesNewExternalWriteInsteadOfRestoringOldClipboard() async throws {
    let pasteboard = makeNamedPasteboard()
    defer { release(pasteboard) }
    pasteboard.clearContents()
    #expect(pasteboard.setString("original", forType: .string))

    let clock = TestClock()
    let fallback = makeFallback(
        pasteboard: pasteboard,
        clock: clock,
        copyEventPoster: { _ in
            pasteboard.clearContents()
            return pasteboard.setString("captured selection", forType: .string)
        },
        textReader: {
            let captured = pasteboard.string(forType: .string)
            pasteboard.clearContents()
            #expect(pasteboard.setString("new external clipboard", forType: .string))
            return captured
        }
    )

    let result = await fallback.capture(applicationPID: 4242)

    #expect(result == .preservationUnavailable)
    #expect(pasteboard.string(forType: .string) == "new external clipboard")
}

@MainActor
@Test func clipboardFallbackAbandonsRestoreWhenClipboardChangesAgain() async throws {
    let pasteboard = makeNamedPasteboard()
    defer { release(pasteboard) }
    pasteboard.clearContents()
    #expect(pasteboard.setString("original", forType: .string))

    let probe = TestProbe()
    let clock = TestClock()
    let fallback = ClipboardSelectionFallback(
        pasteboard: pasteboard,
        configuration: testConfiguration,
        frontmostApplicationPID: { 4242 },
        eventAccessChecker: { true },
        secureInputChecker: { _ in false },
        copyEventPoster: { _ in
            pasteboard.clearContents()
            return pasteboard.setString("captured selection", forType: .string)
        },
        timeProvider: { clock.value },
        sleeper: { nanoseconds in
            if probe.sleepCount == 0 {
                pasteboard.clearContents()
                #expect(pasteboard.setString("external during capture", forType: .string))
            }
            probe.sleepCount += 1
            await clock.sleep(nanoseconds)
        }
    )

    let result = await fallback.capture(applicationPID: 4242)

    #expect(result == .preservationUnavailable)
    #expect(pasteboard.string(forType: .string) == "external during capture")
}

@MainActor
@Test func clipboardFallbackRestoresClipboardWhenCaptureIsCancelled() async throws {
    let pasteboard = makeNamedPasteboard()
    defer { release(pasteboard) }
    let originalItem = NSPasteboardItem()
    #expect(originalItem.setString("original", forType: .string))
    #expect(
        originalItem.setData(
            Data([0x10, 0x20, 0x30]),
            forType: .init("com.onepaw.tests.cancel")
        )
    )
    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([originalItem]))
    let original = try pasteboardDump(pasteboard)

    let probe = TestProbe()
    let clock = TestClock()
    let configuration = ClipboardSelectionFallbackConfiguration(
        initialDelayNanoseconds: 0,
        pollingIntervalNanoseconds: 10,
        stableIntervalNanoseconds: 50,
        timeoutNanoseconds: 100
    )
    let fallback = ClipboardSelectionFallback(
        pasteboard: pasteboard,
        configuration: configuration,
        frontmostApplicationPID: { 4242 },
        eventAccessChecker: { true },
        secureInputChecker: { _ in false },
        copyEventPoster: { _ in
            probe.eventPostCount += 1
            pasteboard.clearContents()
            return pasteboard.setString("temporary selection", forType: .string)
        },
        timeProvider: { clock.value },
        sleeper: { nanoseconds in
            probe.sleepCount += 1
            await clock.sleep(nanoseconds)
        }
    )

    let task = Task { @MainActor in
        await fallback.capture(applicationPID: 4242)
    }
    while probe.sleepCount == 0 {
        await Task.yield()
    }
    task.cancel()
    let result = await task.value

    #expect(result == .cancelled)
    #expect(probe.eventPostCount == 1)
    #expect(try pasteboardDump(pasteboard) == original)
}

@MainActor
@Test func clipboardFallbackRefusesToOverwriteClipboardChangedBeforeCopy() async throws {
    let pasteboard = makeNamedPasteboard()
    defer { release(pasteboard) }
    pasteboard.clearContents()
    #expect(pasteboard.setString("original", forType: .string))

    let probe = TestProbe()
    let clock = TestClock()
    var configuration = testConfiguration
    configuration.initialDelayNanoseconds = 10
    let fallback = ClipboardSelectionFallback(
        pasteboard: pasteboard,
        configuration: configuration,
        frontmostApplicationPID: { 4242 },
        eventAccessChecker: { true },
        secureInputChecker: { _ in false },
        copyEventPoster: { _ in
            probe.eventPostCount += 1
            return true
        },
        timeProvider: { clock.value },
        sleeper: { nanoseconds in
            if probe.sleepCount == 0 {
                pasteboard.clearContents()
                #expect(pasteboard.setString("concurrent clipboard", forType: .string))
            }
            probe.sleepCount += 1
            await clock.sleep(nanoseconds)
        }
    )

    let result = await fallback.capture(applicationPID: 4242)

    #expect(result == .preservationUnavailable)
    #expect(probe.eventPostCount == 0)
    #expect(pasteboard.string(forType: .string) == "concurrent clipboard")
}

@MainActor
private func makeFallback(
    pasteboard: NSPasteboard,
    clock: TestClock,
    secureInputChecker: @escaping ClipboardSelectionFallback.SecureInputChecker = { _ in false },
    copyEventPoster: @escaping ClipboardSelectionFallback.CopyEventPoster,
    textReader: ClipboardSelectionFallback.TextReader? = nil
) -> ClipboardSelectionFallback {
    ClipboardSelectionFallback(
        pasteboard: pasteboard,
        configuration: testConfiguration,
        frontmostApplicationPID: { 4242 },
        eventAccessChecker: { true },
        secureInputChecker: secureInputChecker,
        copyEventPoster: copyEventPoster,
        timeProvider: { clock.value },
        sleeper: { nanoseconds in
            await clock.sleep(nanoseconds)
        },
        textReader: textReader
    )
}

private let testConfiguration = ClipboardSelectionFallbackConfiguration(
    initialDelayNanoseconds: 0,
    pollingIntervalNanoseconds: 10,
    stableIntervalNanoseconds: 20,
    timeoutNanoseconds: 100,
    maximumSnapshotBytes: 1_024 * 1_024,
    maximumItemCount: 16,
    maximumTypesPerItem: 16,
    snapshotAttempts: 2
)

@MainActor
private final class TestClock {
    var value: UInt64 = 0

    func sleep(_ nanoseconds: UInt64) async {
        value += nanoseconds
        await Task.yield()
    }
}

@MainActor
private final class TestProbe {
    var eventPostCount = 0
    var sleepCount = 0
}

private struct PasteboardItemDump: Equatable {
    struct Representation: Equatable {
        let type: String
        let data: Data
    }

    let representations: [Representation]
}

@MainActor
private func makeNamedPasteboard() -> NSPasteboard {
    let name = NSPasteboard.Name("onepaw-clipboard-fallback-tests-\(UUID().uuidString)")
    let pasteboard = NSPasteboard(name: name)
    pasteboard.clearContents()
    return pasteboard
}

@MainActor
private func release(_ pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    pasteboard.releaseGlobally()
}

@MainActor
private func pasteboardDump(_ pasteboard: NSPasteboard) throws -> [PasteboardItemDump] {
    try (pasteboard.pasteboardItems ?? []).map { item in
        let representations = try item.types.map { type in
            let data = try #require(item.data(forType: type))
            return PasteboardItemDump.Representation(
                type: type.rawValue,
                data: Data(data)
            )
        }
        return PasteboardItemDump(representations: representations)
    }
}
