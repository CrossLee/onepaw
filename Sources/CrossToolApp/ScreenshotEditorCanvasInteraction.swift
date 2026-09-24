import CrossToolCore

/// Pure routing for pointer events received by the screenshot editor canvas.
///
/// Keeping this decision separate from SwiftUI's gesture callbacks makes the
/// zero-distance click path testable. In particular, text and sequence tools
/// intentionally do nothing while a drag is changing and enter text editing
/// when that gesture ends.
struct ScreenshotEditorCanvasInteractionRouter: Sendable {
    enum Event: Equatable, Sendable {
        case changed(
            startLocation: ScreenshotEditDisplayPoint,
            location: ScreenshotEditDisplayPoint,
            hasDraftOperation: Bool
        )
        case ended(
            startLocation: ScreenshotEditDisplayPoint,
            location: ScreenshotEditDisplayPoint
        )
    }

    enum Action: Equatable, Sendable {
        case beginInteraction(at: ScreenshotEditPoint)
        case updateInteraction(to: ScreenshotEditPoint)
        case endInteraction(at: ScreenshotEditPoint)
        case beginTextEditing(at: ScreenshotEditPoint)
    }

    let coordinateMapper: ScreenshotEditCoordinateMapper

    func actions(
        for event: Event,
        selectedTool: ScreenshotEditTool
    ) -> [Action] {
        switch (event, selectedTool) {
        case (
            .changed(
                let startLocation,
                let location,
                let hasDraftOperation
            ),
            .pen
        ), (
            .changed(
                let startLocation,
                let location,
                let hasDraftOperation
            ),
            .mosaic
        ), (
            .changed(
                let startLocation,
                let location,
                let hasDraftOperation
            ),
            .rectangle
        ), (
            .changed(
                let startLocation,
                let location,
                let hasDraftOperation
            ),
            .arrow
        ):
            let currentPoint = coordinateMapper.imagePoint(from: location)
            guard !hasDraftOperation else {
                return [.updateInteraction(to: currentPoint)]
            }
            return [
                .beginInteraction(
                    at: coordinateMapper.imagePoint(from: startLocation)
                ),
                .updateInteraction(to: currentPoint),
            ]

        case (.changed, .text), (.changed, .sequence):
            return []

        case (.ended(_, let location), .pen),
             (.ended(_, let location), .mosaic),
             (.ended(_, let location), .rectangle),
             (.ended(_, let location), .arrow):
            return [
                .endInteraction(
                    at: coordinateMapper.imagePoint(from: location)
                ),
            ]

        case (.ended(let startLocation, _), .text),
             (.ended(let startLocation, _), .sequence):
            return [
                .beginTextEditing(
                    at: coordinateMapper.imagePoint(from: startLocation)
                ),
            ]
        }
    }
}
