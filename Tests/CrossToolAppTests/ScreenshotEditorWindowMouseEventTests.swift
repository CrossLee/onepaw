import AppKit
@testable import CrossToolApp
import Testing

@MainActor
@Suite("Screenshot editor window mouse event routing", .serialized)
struct ScreenshotEditorWindowMouseEventTests {
    @Test("Real mouse events pass the Escape gate without reading keyCode")
    func mouseEventsDoNotCrashWindowRouting() throws {
        _ = NSApplication.shared
        let window = ScreenshotEditorWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        var editStateQueryCount = 0
        window.isTextAnnotationEditing = {
            editStateQueryCount += 1
            return false
        }

        for (index, type) in [
            NSEvent.EventType.leftMouseDown,
            .leftMouseUp,
            .mouseMoved,
        ].enumerated() {
            let event = try #require(NSEvent.mouseEvent(
                with: type,
                location: CGPoint(x: 60, y: 60),
                modifierFlags: [],
                timestamp: TimeInterval(index) / 100,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: index + 1,
                clickCount: type == .mouseMoved ? 0 : 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ))
            window.sendEvent(event)
        }

        // Reaching this assertion proves all three real NSEvents traversed
        // ScreenshotEditorWindow.sendEvent without AppKit's invalid-keyCode
        // exception and continued through the editor-state routing path.
        #expect(editStateQueryCount == 3)
    }
}
