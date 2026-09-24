import CrossToolCore
@testable import CrossToolApp
import Testing

@Suite("Screenshot editor canvas interaction routing")
struct ScreenshotEditorCanvasInteractionTests {
    @Test(
        "A zero-distance click enters text or sequence editing",
        arguments: [ScreenshotEditTool.text, .sequence]
    )
    func zeroDistanceClickEntersTextEditing(tool: ScreenshotEditTool) {
        let location = ScreenshotEditDisplayPoint(x: 384, y: 273)

        let actions = Self.router.actions(
            for: .ended(startLocation: location, location: location),
            selectedTool: tool
        )

        #expect(actions == [
            .beginTextEditing(at: ScreenshotEditPoint(x: 1_440, y: 900)),
        ])
    }

    @Test(
        "Text tools wait for gesture end instead of starting a drawing draft",
        arguments: [ScreenshotEditTool.text, .sequence]
    )
    func textToolsIgnoreChangedEvents(tool: ScreenshotEditTool) {
        let actions = Self.router.actions(
            for: .changed(
                startLocation: .init(x: 100, y: 100),
                location: .init(x: 110, y: 105),
                hasDraftOperation: false
            ),
            selectedTool: tool
        )

        #expect(actions.isEmpty)
    }

    @Test(
        "Drawing starts and updates from the first changed event",
        arguments: drawingTools
    )
    func firstDrawingChangeBeginsAndUpdates(tool: ScreenshotEditTool) {
        let actions = Self.router.actions(
            for: .changed(
                startLocation: .init(x: 24, y: 48),
                location: .init(x: 384, y: 273),
                hasDraftOperation: false
            ),
            selectedTool: tool
        )

        #expect(actions == [
            .beginInteraction(at: ScreenshotEditPoint(x: 0, y: 0)),
            .updateInteraction(to: ScreenshotEditPoint(x: 1_440, y: 900)),
        ])
    }

    @Test(
        "An existing drawing draft receives only updates",
        arguments: drawingTools
    )
    func laterDrawingChangeOnlyUpdates(tool: ScreenshotEditTool) {
        let actions = Self.router.actions(
            for: .changed(
                startLocation: .init(x: 24, y: 48),
                location: .init(x: 744, y: 498),
                hasDraftOperation: true
            ),
            selectedTool: tool
        )

        #expect(actions == [
            .updateInteraction(to: ScreenshotEditPoint(x: 2_880, y: 1_800)),
        ])
    }

    @Test(
        "Drawing ends at the current point and clamps outside the image",
        arguments: drawingTools
    )
    func drawingEndUsesCurrentClampedPoint(tool: ScreenshotEditTool) {
        let actions = Self.router.actions(
            for: .ended(
                startLocation: .init(x: 100, y: 100),
                location: .init(x: 2_000, y: -500)
            ),
            selectedTool: tool
        )

        #expect(actions == [
            .endInteraction(at: ScreenshotEditPoint(x: 2_880, y: 0)),
        ])
    }

    @Test(
        "Text placement uses the click-down point rather than drag end",
        arguments: [ScreenshotEditTool.text, .sequence]
    )
    func textPlacementUsesGestureStart(tool: ScreenshotEditTool) {
        let actions = Self.router.actions(
            for: .ended(
                startLocation: .init(x: 204, y: 160.5),
                location: .init(x: 744, y: 498)
            ),
            selectedTool: tool
        )

        #expect(actions == [
            .beginTextEditing(at: ScreenshotEditPoint(x: 720, y: 450)),
        ])
    }

    private static let router = ScreenshotEditorCanvasInteractionRouter(
        coordinateMapper: ScreenshotEditCoordinateMapper(
            displayOriginX: 24,
            displayOriginY: 48,
            displayWidth: 720,
            displayHeight: 450,
            imagePixelWidth: 2_880,
            imagePixelHeight: 1_800
        )
    )

    private static let drawingTools: [ScreenshotEditTool] = [
        .pen,
        .mosaic,
        .rectangle,
        .arrow,
    ]
}
