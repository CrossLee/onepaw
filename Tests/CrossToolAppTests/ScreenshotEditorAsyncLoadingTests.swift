import AppKit
@testable import CrossToolApp
import Testing

@MainActor
@Suite("Screenshot editor asynchronous loading", .serialized)
struct ScreenshotEditorAsyncLoadingTests {
    @Test("The loading window is visible while full-image decoding is suspended")
    func presentsBeforeFinishingFullImageDecode() async throws {
        _ = NSApplication.shared
        let sourceURL = Self.fixtureURL
        let decodedImage = try await ScreenshotEditorRenderer.decodeImage(at: sourceURL)
        let loader = DeferredScreenshotEditorImageLoader(
            expectedURL: sourceURL,
            result: decodedImage
        )
        let controller = try ScreenshotEditorWindowController(
            sourceURL: sourceURL,
            originalWasAutomaticallyCopied: true,
            onSharePNG: { _ in },
            onClose: {},
            imageLoader: { url in
                try await loader.load(url)
            }
        )
        let window = try #require(controller.window)
        defer {
            window.delegate = nil
            window.orderOut(nil)
            NSApp.deactivate()
        }

        #expect(await loader.snapshot().callCount == 0)
        #expect(!controller.isEditorReady)

        _ = controller.show()
        let started = await waitUntilLoaderStarts(loader)

        #expect(started.callCount == 1)
        #expect(started.receivedURL == sourceURL)
        #expect(window.isVisible)
        #expect(!controller.isEditorReady)
        #expect(controller.imageLoadErrorMessage == nil)

        await loader.release()
        await controller.waitUntilImageLoadFinishes()

        #expect(controller.isEditorReady)
        #expect(controller.imageLoadErrorMessage == nil)
    }

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Brand/OnePaw-AppIcon.png")
    }

    private func waitUntilLoaderStarts(
        _ loader: DeferredScreenshotEditorImageLoader
    ) async -> DeferredScreenshotEditorImageLoader.Snapshot {
        for _ in 0..<100 {
            let snapshot = await loader.snapshot()
            if snapshot.callCount > 0 {
                return snapshot
            }
            await Task.yield()
        }
        return await loader.snapshot()
    }
}

private actor DeferredScreenshotEditorImageLoader {
    struct Snapshot: Sendable {
        let callCount: Int
        let receivedURL: URL?
    }

    private let expectedURL: URL
    private let result: ScreenshotEditorDecodedImage
    private var callCount = 0
    private var receivedURL: URL?
    private var isReleased = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(expectedURL: URL, result: ScreenshotEditorDecodedImage) {
        self.expectedURL = expectedURL
        self.result = result
    }

    func load(_ url: URL) async throws -> ScreenshotEditorDecodedImage {
        callCount += 1
        receivedURL = url
        guard url == expectedURL else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return result
    }

    func snapshot() -> Snapshot {
        Snapshot(callCount: callCount, receivedURL: receivedURL)
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
