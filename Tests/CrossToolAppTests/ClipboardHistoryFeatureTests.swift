import AppKit
import CrossToolCore
import Foundation
import Testing
@testable import CrossToolApp

@MainActor
@Suite("Clipboard history feature", .serialized)
struct ClipboardHistoryFeatureTests {
    @Test("Pasteboard permission states allow one approved first read without repeated prompts")
    func pasteboardPermissionStatePolicy() {
        #expect(ClipboardHistoryPasteboardAccessState.legacyAllowed.allowsAutomaticReadAttempt)
        #expect(ClipboardHistoryPasteboardAccessState.notRequested.allowsAutomaticReadAttempt)
        #expect(ClipboardHistoryPasteboardAccessState.alwaysAllowed.allowsAutomaticReadAttempt)
        #expect(!ClipboardHistoryPasteboardAccessState.askEveryTime.allowsAutomaticReadAttempt)
        #expect(!ClipboardHistoryPasteboardAccessState.denied.allowsAutomaticReadAttempt)

        #expect(
            ClipboardHistoryPasteboardAccessState.askEveryTime
                .allowsAuthorizedGenerationCommit
        )
        #expect(
            !ClipboardHistoryPasteboardAccessState.denied
                .allowsAuthorizedGenerationCommit
        )
    }

    @Test("Nested suppression keeps delayed-write risk until the final lease finishes")
    func nestedSuppressionRetainsDelayedWriteRisk() {
        let clock = ClipboardHistoryTestClock()
        let gate = ClipboardHistoryObservationGate(
            delayedWriteQuietPeriodNanoseconds: 100,
            uptimeProvider: { clock.value }
        )
        let first = gate.beginSuppression()
        let second = gate.beginSuppression()

        gate.finishSuppression(
            first,
            settledChangeCount: 1,
            mayReceiveDelayedWrite: true
        )
        gate.finishSuppression(second, settledChangeCount: 2)

        clock.value = 50
        #expect(gate.shouldSuppress(changeCount: 3))
        clock.value = 200
        #expect(!gate.shouldSuppress(changeCount: 4))
    }

    @Test("A synchronous OnePaw copy cannot erase an active delayed-copy guard")
    func internalCopyPreservesDelayedGuard() {
        let clock = ClipboardHistoryTestClock()
        let gate = ClipboardHistoryObservationGate(
            delayedWriteQuietPeriodNanoseconds: 100,
            uptimeProvider: { clock.value }
        )
        let quickTranslation = gate.beginSuppression()
        gate.finishSuppression(
            quickTranslation,
            settledChangeCount: 1,
            mayReceiveDelayedWrite: true
        )

        let internalCopy = gate.beginSuppression()
        gate.finishSuppression(internalCopy, settledChangeCount: 2)

        clock.value = 50
        #expect(gate.shouldSuppress(changeCount: 3))
        clock.value = 200
        #expect(!gate.shouldSuppress(changeCount: 4))
    }

    @Test("Starting establishes a baseline without importing old clipboard content")
    func startupBaselineDoesNotImportExistingContent() async throws {
        try await withFixture { fixture in
            fixture.writeText("启动前已经存在的内容")

            fixture.model.start()
            fixture.model.stop()
            await fixture.model.pollNow()

            #expect(fixture.model.items.isEmpty)

            fixture.writeText("启动后的真实复制")
            await fixture.model.pollNow()

            #expect(fixture.model.items.count == 1)
            #expect(fixture.model.items.first?.content == .text("启动后的真实复制"))
        }
    }

    @Test("Text is preserved exactly while blank, sensitive, and file URL items are skipped")
    func filtersUnsupportedAndSensitiveTextCaptures() async throws {
        try await withFixture { fixture in
            fixture.model.start()
            fixture.model.stop()

            let original = "\n  保留两端空格  \t"
            fixture.writeText(original)
            await fixture.model.pollNow()
            #expect(fixture.model.items.map(\.content) == [.text(original)])

            fixture.writeText(" \n\t ")
            await fixture.model.pollNow()
            #expect(fixture.model.items.map(\.content) == [.text(original)])

            let sensitiveItem = NSPasteboardItem()
            #expect(sensitiveItem.setString("不应保存的密码", forType: .string))
            #expect(
                sensitiveItem.setData(
                    Data([0x01]),
                    forType: .init("org.nspasteboard.ConcealedType")
                )
            )
            fixture.write(sensitiveItem)
            await fixture.model.pollNow()
            #expect(fixture.model.items.map(\.content) == [.text(original)])

            let fileItem = NSPasteboardItem()
            #expect(fileItem.setString("本地文件", forType: .string))
            #expect(
                fileItem.setString(
                    "file:///tmp/onepaw-private-file.txt",
                    forType: .fileURL
                )
            )
            fixture.write(fileItem)
            await fixture.model.pollNow()
            #expect(fixture.model.items.map(\.content) == [.text(original)])
        }
    }

    @Test("Secure input prevents clipboard content from entering history")
    func secureInputSkipsCapture() async throws {
        try await withFixture(secureInputChecker: { true }) { fixture in
            fixture.model.start()
            fixture.model.stop()

            fixture.writeText("密码输入期间不应记录")
            await fixture.model.pollNow()

            #expect(fixture.model.items.isEmpty)
        }
    }

    @Test("Secure input also blocks direct automatic-screenshot history writes")
    func secureInputSkipsAutomaticScreenshotCapture() async throws {
        try await withFixture(secureInputChecker: { true }) { fixture in
            let png = try #require(
                Data(
                    base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9WlG4v8AAAAASUVORK5CYII="
                )
            )

            await fixture.model.recordAutomaticallyCopiedScreenshotPNG(png)

            #expect(fixture.model.items.isEmpty)
            let payloads = try FileManager.default.contentsOfDirectory(
                at: fixture.historyDirectory.appendingPathComponent("Items"),
                includingPropertiesForKeys: nil
            )
            #expect(payloads.isEmpty)
        }
    }

    @Test("Maximum count persists and trims existing records immediately")
    func maximumCountPersistsAndTrims() async throws {
        try await withFixture { fixture in
            fixture.model.start()
            fixture.model.stop()

            for text in ["第一条", "第二条", "第三条"] {
                fixture.writeText(text)
                await fixture.model.pollNow()
            }
            #expect(fixture.model.items.count == 3)

            fixture.model.setMaximumItemCount(2)
            try await waitUntil {
                fixture.model.items.count == 2
            }

            #expect(fixture.model.maximumItemCount == 2)
            #expect(
                fixture.defaults.integer(
                    forKey: ClipboardHistoryFeatureModel.maximumItemCountDefaultsKey
                ) == 2
            )
            #expect(fixture.model.items.map(\.content) == [
                .text("第三条"),
                .text("第二条"),
            ])

            let reloaded = ClipboardHistoryFeatureModel(
                directory: fixture.historyDirectory,
                defaults: fixture.defaults,
                pasteboard: fixture.pasteboard,
                observationGate: fixture.gate,
                secureInputChecker: { false }
            )
            defer { reloaded.stop() }
            await reloaded.reload()

            #expect(reloaded.maximumItemCount == 2)
            #expect(reloaded.items.map(\.content) == [
                .text("第三条"),
                .text("第二条"),
            ])
        }
    }

    @Test("A user-copied valid PNG is recorded and can be read back as a thumbnail")
    func recordsAndReadsValidPNG() async throws {
        try await withFixture { fixture in
            fixture.model.start()
            fixture.model.stop()

            let png = try #require(
                Data(
                    base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9WlG4v8AAAAASUVORK5CYII="
                )
            )
            try ScreenshotPasteboardWriter(pasteboard: fixture.pasteboard)
                .writePNG(png, tiffData: nil)
            await fixture.model.pollNow()

            let recorded = try #require(fixture.model.items.first)
            guard case .image(let metadata) = recorded.content else {
                Issue.record("Expected the PNG to be stored as an image history item")
                return
            }
            #expect(metadata.pasteboardType == NSPasteboard.PasteboardType.png.rawValue)
            #expect(metadata.pixelWidth == 1)
            #expect(metadata.pixelHeight == 1)
            #expect(metadata.byteCount == Int64(png.count))
            #expect(await fixture.model.thumbnail(for: recorded) != nil)
            let detailImage = await fixture.model.detailImage(for: recorded)
            #expect(detailImage?.size == NSSize(width: 1, height: 1))

            let payloads = try FileManager.default.contentsOfDirectory(
                at: fixture.historyDirectory.appendingPathComponent("Items"),
                includingPropertiesForKeys: nil
            )
            let payload = try #require(payloads.first)
            #expect(try Data(contentsOf: payload) == png)
        }
    }

    @Test("OnePaw screenshot history reuses written PNG bytes and normal copying resumes")
    func screenshotCopyReusesPNGBytesForHistory() async throws {
        try await withFixture { fixture in
            fixture.model.start()
            fixture.model.stop()

            let png = try #require(
                Data(
                    base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9WlG4v8AAAAASUVORK5CYII="
                )
            )
            try ScreenshotPasteboardWriter(
                pasteboard: fixture.pasteboard,
                marksAsAutoGenerated: true
            ).writePNG(png, tiffData: nil)

            #expect(fixture.pasteboard.data(forType: .png) == png)
            await fixture.model.pollNow()
            #expect(fixture.model.items.isEmpty)

            await fixture.model.recordAutomaticallyCopiedScreenshotPNG(png)
            let screenshotItem = try #require(fixture.model.items.first)
            guard case .image(let metadata) = screenshotItem.content else {
                Issue.record("Expected the reused screenshot bytes to enter history")
                return
            }
            #expect(metadata.pasteboardType == NSPasteboard.PasteboardType.png.rawValue)
            #expect(metadata.byteCount == Int64(png.count))

            fixture.writeText("用户下一次正常复制")
            await fixture.model.pollNow()

            #expect(fixture.model.items.map(\.content) == [
                .text("用户下一次正常复制"),
                screenshotItem.content,
            ])
        }
    }

    @Test("Auto-generated marker skips promised PNG materialization")
    func autoGeneratedMarkerSkipsPromisedPNGMaterialization() throws {
        let pasteboard = NSPasteboard(
            name: .init("onepaw-auto-generated-reader-test-\(UUID())")
        )
        defer { pasteboard.releaseGlobally() }

        let provider = CountingPasteboardDataProvider()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.png])
        #expect(
            item.setData(
                Data(),
                forType: ClipboardHistoryPasteboardType.autoGenerated
            )
        )
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([item]))

        let candidate = ClipboardHistoryPasteboardReader.candidate(
            from: pasteboard,
            expectedChangeCount: pasteboard.changeCount
        )

        #expect(candidate == nil)
        #expect(provider.requestCount == 0)
    }

    @Test("Clearing history invalidates a capture still being validated")
    func clearInvalidatesInFlightCapture() async throws {
        let processor = BlockingClipboardHistoryCaptureProcessor()
        try await withFixture(captureProcessor: processor) { fixture in
            fixture.model.start()
            fixture.model.stop()
            fixture.writeText("清空后不应重新出现")

            let pollTask = Task { @MainActor in
                await fixture.model.pollNow()
            }
            var didStart = false
            for _ in 0 ..< 200 {
                if await processor.hasStarted {
                    didStart = true
                    break
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(didStart)
            guard didStart else {
                pollTask.cancel()
                return
            }

            await fixture.model.clear()
            await processor.resume()
            await pollTask.value

            #expect(fixture.model.items.isEmpty)
        }
    }

    @Test("Quick-translation fallback is excluded but the next real copy is recorded")
    func selectedTextFallbackDoesNotEnterHistory() async throws {
        try await withFixture { fixture in
            fixture.writeText("用户原来的剪贴板")
            fixture.model.start()
            fixture.model.stop()

            let clock = ClipboardHistoryTestClock()
            let fallback = ClipboardSelectionFallback(
                pasteboard: fixture.pasteboard,
                configuration: .init(
                    initialDelayNanoseconds: 0,
                    pollingIntervalNanoseconds: 10,
                    stableIntervalNanoseconds: 20,
                    timeoutNanoseconds: 100,
                    maximumSnapshotBytes: 1_024 * 1_024,
                    maximumItemCount: 16,
                    maximumTypesPerItem: 16,
                    snapshotAttempts: 2
                ),
                frontmostApplicationPID: { 4242 },
                eventAccessChecker: { true },
                secureInputChecker: { _ in false },
                copyEventPoster: { _ in
                    fixture.pasteboard.clearContents()
                    return fixture.pasteboard.setString(
                        "快捷翻译的临时选区",
                        forType: .string
                    )
                },
                timeProvider: { clock.value },
                sleeper: { nanoseconds in
                    clock.value += nanoseconds
                    // Observe the temporary selection while the shared gate is
                    // active. It must be ignored even though changeCount moved.
                    await fixture.model.pollNow()
                    await Task.yield()
                },
                clipboardHistoryObservationGate: fixture.gate
            )

            let result = await fallback.capture(applicationPID: 4242)
            #expect(result == .selected("快捷翻译的临时选区"))
            #expect(fixture.pasteboard.string(forType: .string) == "用户原来的剪贴板")
            #expect(fixture.model.items.isEmpty)

            // Observe the restored generation after suppression has settled.
            // The gate must exclude this half of the fallback transaction too.
            await fixture.model.pollNow()
            #expect(fixture.model.items.isEmpty)

            fixture.writeText("用户下一次真实复制")
            await fixture.model.pollNow()

            #expect(fixture.model.items.map(\.content) == [
                .text("用户下一次真实复制"),
            ])
        }
    }

    @Test("A delayed quick-translation copy is quarantined before normal history resumes")
    func delayedSelectedTextCopyDoesNotEnterHistory() async throws {
        let gateClock = ClipboardHistoryTestClock()
        let gate = ClipboardHistoryObservationGate(
            delayedWriteQuietPeriodNanoseconds: 100,
            uptimeProvider: { gateClock.value }
        )
        try await withFixture(gate: gate) { fixture in
            fixture.writeText("用户原来的剪贴板")
            fixture.model.start()
            fixture.model.stop()

            let fallbackClock = ClipboardHistoryTestClock()
            let fallback = ClipboardSelectionFallback(
                pasteboard: fixture.pasteboard,
                configuration: .init(
                    initialDelayNanoseconds: 0,
                    pollingIntervalNanoseconds: 10,
                    stableIntervalNanoseconds: 20,
                    timeoutNanoseconds: 50,
                    maximumSnapshotBytes: 1_024 * 1_024,
                    maximumItemCount: 16,
                    maximumTypesPerItem: 16,
                    snapshotAttempts: 2
                ),
                frontmostApplicationPID: { 4242 },
                eventAccessChecker: { true },
                secureInputChecker: { _ in false },
                copyEventPoster: { _ in true },
                timeProvider: { fallbackClock.value },
                sleeper: { nanoseconds in
                    fallbackClock.value += nanoseconds
                    await Task.yield()
                },
                clipboardHistoryObservationGate: fixture.gate
            )

            #expect(await fallback.capture(applicationPID: 4242) == .noSelection)

            // Simulate the target application handling Command-C only after
            // the fallback itself has timed out and returned.
            gateClock.value = 50
            fixture.writeText("延迟到达的快捷翻译选区")
            await fixture.model.pollNow()
            #expect(fixture.model.items.isEmpty)

            gateClock.value = 200
            fixture.writeText("之后的正常复制")
            await fixture.model.pollNow()
            #expect(fixture.model.items.map(\.content) == [.text("之后的正常复制")])
        }
    }

    @Test("A failed quick translation stops suppressing after its bounded guard period")
    func failedFallbackDoesNotDiscardLaterNormalCopy() async throws {
        let gateClock = ClipboardHistoryTestClock()
        let gate = ClipboardHistoryObservationGate(
            delayedWriteQuietPeriodNanoseconds: 100,
            uptimeProvider: { gateClock.value }
        )
        try await withFixture(gate: gate) { fixture in
            fixture.writeText("原剪贴板")
            fixture.model.start()
            fixture.model.stop()

            let fallbackClock = ClipboardHistoryTestClock()
            let fallback = ClipboardSelectionFallback(
                pasteboard: fixture.pasteboard,
                configuration: .init(
                    initialDelayNanoseconds: 0,
                    pollingIntervalNanoseconds: 10,
                    stableIntervalNanoseconds: 20,
                    timeoutNanoseconds: 50
                ),
                frontmostApplicationPID: { 4242 },
                eventAccessChecker: { true },
                secureInputChecker: { _ in false },
                copyEventPoster: { _ in true },
                timeProvider: { fallbackClock.value },
                sleeper: { nanoseconds in
                    fallbackClock.value += nanoseconds
                    await Task.yield()
                },
                clipboardHistoryObservationGate: fixture.gate
            )

            #expect(await fallback.capture(applicationPID: 4242) == .noSelection)

            gateClock.value = 101
            fixture.writeText("稍后发生的正常复制")
            await fixture.model.pollNow()
            #expect(fixture.model.items.map(\.content) == [.text("稍后发生的正常复制")])
        }
    }
}

@MainActor
private final class ClipboardHistoryFeatureFixture {
    let root: URL
    let historyDirectory: URL
    let defaultsSuiteName: String
    let defaults: UserDefaults
    let pasteboard: NSPasteboard
    let gate: ClipboardHistoryObservationGate
    let model: ClipboardHistoryFeatureModel

    init(
        gate injectedGate: ClipboardHistoryObservationGate? = nil,
        secureInputChecker: @escaping @MainActor @Sendable () -> Bool = { false },
        captureProcessor: (any ClipboardHistoryCaptureProcessing)? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "onepaw-clipboard-history-feature-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        historyDirectory = root.appendingPathComponent(
            "ClipboardHistory",
            isDirectory: true
        )

        defaultsSuiteName = "com.onepaw.tests.clipboard-history.\(UUID().uuidString)"
        guard let isolatedDefaults = UserDefaults(suiteName: defaultsSuiteName) else {
            throw ClipboardHistoryFeatureFixtureError.defaultsUnavailable
        }
        defaults = isolatedDefaults
        defaults.removePersistentDomain(forName: defaultsSuiteName)

        let pasteboardName = NSPasteboard.Name(
            "onepaw-clipboard-history-tests-\(UUID().uuidString)"
        )
        pasteboard = NSPasteboard(name: pasteboardName)
        pasteboard.clearContents()

        gate = injectedGate ?? ClipboardHistoryObservationGate()
        model = ClipboardHistoryFeatureModel(
            directory: historyDirectory,
            defaults: defaults,
            pasteboard: pasteboard,
            observationGate: gate,
            secureInputChecker: secureInputChecker,
            captureProcessor: captureProcessor
        )
    }

    func writeText(_ text: String) {
        pasteboard.clearContents()
        #expect(pasteboard.setString(text, forType: .string))
    }

    func write(_ item: NSPasteboardItem) {
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([item]))
    }

    func cleanup() async {
        model.stop()
        await model.clear()
        pasteboard.clearContents()
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class ClipboardHistoryTestClock {
    var value: UInt64 = 0
}

private final class CountingPasteboardDataProvider: NSObject, NSPasteboardItemDataProvider {
    private(set) var requestCount = 0

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        requestCount += 1
        #expect(item.setData(Data([0x01]), forType: type))
    }
}

private actor BlockingClipboardHistoryCaptureProcessor: ClipboardHistoryCaptureProcessing {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var hasStarted = false

    func capture(
        from candidate: ClipboardHistoryPasteboardCandidate
    ) async -> ClipboardHistoryCapture? {
        hasStarted = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        switch candidate {
        case .text(let text):
            return .text(text)
        case .image(let data, let pasteboardType, let fileExtension):
            return .image(
                data: data,
                pasteboardType: pasteboardType,
                pixelWidth: 1,
                pixelHeight: 1,
                fileExtension: fileExtension
            )
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private enum ClipboardHistoryFeatureFixtureError: Error {
    case defaultsUnavailable
}

@MainActor
private func withFixture(
    gate: ClipboardHistoryObservationGate? = nil,
    secureInputChecker: @escaping @MainActor @Sendable () -> Bool = { false },
    captureProcessor: (any ClipboardHistoryCaptureProcessing)? = nil,
    _ body: @MainActor (ClipboardHistoryFeatureFixture) async throws -> Void
) async throws {
    let fixture = try ClipboardHistoryFeatureFixture(
        gate: gate,
        secureInputChecker: secureInputChecker,
        captureProcessor: captureProcessor
    )
    do {
        try await body(fixture)
    } catch {
        await fixture.cleanup()
        throw error
    }
    await fixture.cleanup()
}

@MainActor
private func waitUntil(
    attempts: Int = 200,
    condition: @MainActor () -> Bool
) async throws {
    for _ in 0 ..< attempts {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition(), "Timed out waiting for clipboard history state")
}
