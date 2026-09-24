import Foundation
import Testing
@testable import CrossToolCore

@Test func screenshotEditToolsKeepStableToolbarOrderIncludingTextAndSequence() {
    #expect(ScreenshotEditTool.allCases == [
        .pen,
        .mosaic,
        .rectangle,
        .arrow,
        .text,
        .sequence,
    ])
}

@Test func screenshotEditHistoryCommitsEveryOperationKindInOrder() {
    let pen = ScreenshotEditOperation.freehand(
        ScreenshotFreehandStroke(
            id: fixedID(1),
            points: [point(10, 20), point(30, 40)],
            color: .red,
            lineWidth: 5
        )
    )
    let mosaic = ScreenshotEditOperation.mosaic(
        ScreenshotMosaicStroke(
            id: fixedID(2),
            points: [point(50, 60)],
            brushDiameter: 42,
            pixelSize: 14
        )
    )
    let rectangle = ScreenshotEditOperation.rectangle(
        ScreenshotRectangleAnnotation(
            id: fixedID(3),
            start: point(100, 80),
            end: point(20, 10),
            color: .blue,
            lineWidth: 3
        )
    )
    let arrow = ScreenshotEditOperation.arrow(
        ScreenshotArrowAnnotation(
            id: fixedID(4),
            start: point(1, 2),
            end: point(30, 50),
            color: .yellow,
            lineWidth: 6
        )
    )

    var history = ScreenshotEditHistory()
    [pen, mosaic, rectangle, arrow].forEach { history.commit($0) }

    #expect(history.operations == [pen, mosaic, rectangle, arrow])
    #expect(history.operations.map(\.tool) == [.pen, .mosaic, .rectangle, .arrow])
    #expect(history.undoCount == 4)
    #expect(history.redoCount == 0)
    #expect(history.canUndo)
    #expect(!history.canRedo)
    #expect(!history.isEmpty)

    if case let .rectangle(rectanglePayload) = rectangle {
        #expect(rectanglePayload.minX == 20)
        #expect(rectanglePayload.minY == 10)
        #expect(rectanglePayload.width == 80)
        #expect(rectanglePayload.height == 70)
    } else {
        Issue.record("Expected a rectangle operation")
    }
}

@Test func screenshotTextAndSequenceOperationsPreserveTheirCompletePayloads() {
    let text = ScreenshotEditOperation.text(
        ScreenshotTextAnnotation(
            id: fixedID(5),
            origin: point(120, 80),
            text: "第一处说明",
            color: .purple,
            fontSize: 36
        )
    )
    let sequence = ScreenshotEditOperation.sequence(
        ScreenshotSequenceAnnotation(
            id: fixedID(6),
            origin: point(320, 180),
            number: 7,
            text: "下一步",
            color: .orange,
            fontSize: 42
        )
    )
    var history = ScreenshotEditHistory()

    history.commit(text)
    history.commit(sequence)

    #expect(history.operations == [text, sequence])
    #expect(history.operations.map(\.tool) == [.text, .sequence])
    #expect(text.id == fixedID(5))
    #expect(sequence.id == fixedID(6))

    guard case .text(let textPayload) = history.operations[0],
          case .sequence(let sequencePayload) = history.operations[1] else {
        Issue.record("Expected text followed by sequence operations")
        return
    }
    #expect(textPayload.origin == point(120, 80))
    #expect(textPayload.text == "第一处说明")
    #expect(textPayload.color == .purple)
    #expect(textPayload.fontSize == 36)
    #expect(sequencePayload.origin == point(320, 180))
    #expect(sequencePayload.number == 7)
    #expect(sequencePayload.text == "下一步")
    #expect(sequencePayload.color == .orange)
    #expect(sequencePayload.fontSize == 42)
    #expect(sequencePayload.badgeDiameter > 0)
    #expect(sequencePayload.badgeFontSize > 0)
    #expect(sequencePayload.textGap > 0)

    let sixDigitSequence = ScreenshotSequenceAnnotation(
        origin: sequencePayload.origin,
        number: 999_999,
        color: sequencePayload.color,
        fontSize: sequencePayload.fontSize
    )
    #expect(sixDigitSequence.badgeDiameter == sequencePayload.badgeDiameter)
    #expect(sixDigitSequence.badgeFontSize < sequencePayload.badgeFontSize)

    #expect(history.undo() == sequence)
    #expect(history.undo() == text)
    #expect(history.operations.isEmpty)
    #expect(history.redo() == text)
    #expect(history.redo() == sequence)
    #expect(history.operations == [text, sequence])
}

@Test func screenshotEditHistoryUndoAndRedoRestoreExactOrder() {
    let first = makeArrow(id: 10)
    let second = makeArrow(id: 11)
    let third = makeArrow(id: 12)
    var history = ScreenshotEditHistory(operations: [first, second, third])

    #expect(history.undo() == third)
    #expect(history.undo() == second)
    #expect(history.operations == [first])
    #expect(history.undoCount == 1)
    #expect(history.redoCount == 2)

    #expect(history.redo() == second)
    #expect(history.redo() == third)
    #expect(history.operations == [first, second, third])
    #expect(history.canUndo)
    #expect(!history.canRedo)
}

@Test func screenshotEditCommitAfterUndoDiscardsRedoBranch() {
    let first = makeArrow(id: 20)
    let discarded = makeArrow(id: 21)
    let replacement = makeArrow(id: 22)
    var history = ScreenshotEditHistory(operations: [first, discarded])

    #expect(history.undo() == discarded)
    #expect(history.canRedo)

    history.commit(replacement)

    #expect(history.operations == [first, replacement])
    #expect(!history.canRedo)
    #expect(history.redoCount == 0)
    #expect(history.redo() == nil)
}

@Test func screenshotEditResetClearsOperationsAndBothHistoryBranches() {
    let first = makeArrow(id: 30)
    let second = makeArrow(id: 31)
    var history = ScreenshotEditHistory(operations: [first, second])
    #expect(history.undo() == second)

    history.reset()

    #expect(history.operations.isEmpty)
    #expect(history.isEmpty)
    #expect(!history.canUndo)
    #expect(!history.canRedo)
    #expect(history.undoCount == 0)
    #expect(history.redoCount == 0)
    #expect(history.undo() == nil)
    #expect(history.redo() == nil)
}

@Test func screenshotEditEmptyHistoryBoundariesAreNoOps() {
    var history = ScreenshotEditHistory()

    #expect(history.undo() == nil)
    #expect(history.redo() == nil)
    history.reset()

    #expect(history == ScreenshotEditHistory())
}

@Test func screenshotRGBAColorNormalizesComponentsAndSupports8BitInput() {
    let normalized = ScreenshotRGBAColor(
        red: -1,
        green: 0.25,
        blue: 2,
        alpha: .infinity
    )

    #expect(normalized == ScreenshotRGBAColor(red: 0, green: 0.25, blue: 1, alpha: 1))
    #expect(ScreenshotRGBAColor.from8Bit(red: 255, green: 0, blue: 128).red == 1)
    #expect(ScreenshotRGBAColor.from8Bit(red: 255, green: 0, blue: 128).blue == 128.0 / 255.0)
}

@Test func screenshotEditCoordinateMapperAccountsForCanvasLetterboxing() {
    let mapper = ScreenshotEditCoordinateMapper(
        displayOriginX: 24,
        displayOriginY: 48,
        displayWidth: 720,
        displayHeight: 450,
        imagePixelWidth: 2_880,
        imagePixelHeight: 1_800
    )

    #expect(mapper.imagePoint(from: .init(x: 24, y: 48)) == point(0, 0))
    #expect(mapper.imagePoint(from: .init(x: 384, y: 273)) == point(1_440, 900))
    #expect(mapper.imagePoint(from: .init(x: 744, y: 498)) == point(2_880, 1_800))
}

@Test func screenshotEditCoordinateMapperClampsAndRoundTripsRetinaPixels() {
    let mapper = ScreenshotEditCoordinateMapper(
        displayOriginX: 24,
        displayOriginY: 48,
        displayWidth: 720,
        displayHeight: 450,
        imagePixelWidth: 2_880,
        imagePixelHeight: 1_800
    )

    #expect(mapper.imagePoint(from: .init(x: -500, y: 2_000)) == point(0, 1_800))

    let displayPoint = mapper.displayPoint(from: point(720, 450))
    #expect(displayPoint == ScreenshotEditDisplayPoint(x: 204, y: 160.5))
    #expect(mapper.imagePoint(from: displayPoint) == point(720, 450))
    #expect(mapper.displayLength(fromImagePixels: 16) == 4)
}

private func makeArrow(id: UInt8) -> ScreenshotEditOperation {
    .arrow(
        ScreenshotArrowAnnotation(
            id: fixedID(id),
            start: point(0, 0),
            end: point(Double(id), Double(id) + 1),
            color: .purple
        )
    )
}

private func point(_ x: Double, _ y: Double) -> ScreenshotEditPoint {
    ScreenshotEditPoint(x: x, y: y)
}

private func fixedID(_ value: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value, 0, 0, 0, value))
}
