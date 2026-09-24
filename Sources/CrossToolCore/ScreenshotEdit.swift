import Foundation

/// A tool that creates an operation in the screenshot editor.
public enum ScreenshotEditTool: String, CaseIterable, Equatable, Sendable {
    case pen
    case mosaic
    case rectangle
    case arrow
    case text
    case sequence
}

/// An RGBA color whose components are normalized to the closed range `0...1`.
public struct ScreenshotRGBAColor: Equatable, Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.normalized(red, fallback: 0)
        self.green = Self.normalized(green, fallback: 0)
        self.blue = Self.normalized(blue, fallback: 0)
        self.alpha = Self.normalized(alpha, fallback: 1)
    }

    /// Creates a color from common 8-bit channel values.
    public static func from8Bit(
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        alpha: UInt8 = 255
    ) -> ScreenshotRGBAColor {
        ScreenshotRGBAColor(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            alpha: Double(alpha) / 255
        )
    }

    public static let black = ScreenshotRGBAColor(red: 0, green: 0, blue: 0)
    public static let white = ScreenshotRGBAColor(red: 1, green: 1, blue: 1)
    public static let red = ScreenshotRGBAColor.from8Bit(red: 239, green: 68, blue: 68)
    public static let orange = ScreenshotRGBAColor.from8Bit(red: 249, green: 115, blue: 22)
    public static let yellow = ScreenshotRGBAColor.from8Bit(red: 234, green: 179, blue: 8)
    public static let green = ScreenshotRGBAColor.from8Bit(red: 34, green: 197, blue: 94)
    public static let blue = ScreenshotRGBAColor.from8Bit(red: 59, green: 130, blue: 246)
    public static let purple = ScreenshotRGBAColor.from8Bit(red: 139, green: 92, blue: 246)

    private static func normalized(_ component: Double, fallback: Double) -> Double {
        guard component.isFinite else { return fallback }
        return min(max(component, 0), 1)
    }
}

/// A point in source-image pixel coordinates.
///
/// The editor uses the source image's top-left corner as `(0, 0)`, with `x`
/// increasing to the right and `y` increasing downwards. Views are responsible
/// for converting display coordinates to this pixel space before committing an
/// operation.
public struct ScreenshotEditPoint: Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var isFinite: Bool {
        x.isFinite && y.isFinite
    }
}

/// A point in the screenshot editor's visible canvas coordinate space.
///
/// Canvas coordinates use the same top-left origin as SwiftUI. Keeping this
/// type separate from ``ScreenshotEditPoint`` makes it harder to accidentally
/// treat a point in the surrounding editor canvas as a source-image pixel.
public struct ScreenshotEditDisplayPoint: Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Converts between an aspect-fitted image rect in the editor and source-image
/// pixel coordinates. Every annotation tool shares this transform.
public struct ScreenshotEditCoordinateMapper: Equatable, Sendable {
    public let displayOriginX: Double
    public let displayOriginY: Double
    public let displayWidth: Double
    public let displayHeight: Double
    public let imagePixelWidth: Double
    public let imagePixelHeight: Double

    public init(
        displayOriginX: Double,
        displayOriginY: Double,
        displayWidth: Double,
        displayHeight: Double,
        imagePixelWidth: Int,
        imagePixelHeight: Int
    ) {
        self.displayOriginX = displayOriginX.isFinite ? displayOriginX : 0
        self.displayOriginY = displayOriginY.isFinite ? displayOriginY : 0
        self.displayWidth = Self.positiveDimension(displayWidth)
        self.displayHeight = Self.positiveDimension(displayHeight)
        self.imagePixelWidth = Double(max(1, imagePixelWidth))
        self.imagePixelHeight = Double(max(1, imagePixelHeight))
    }

    /// Maps a point from the full editor canvas into top-left source pixels.
    /// Points dragged beyond the image edge are clamped to the image bounds.
    public func imagePoint(from displayPoint: ScreenshotEditDisplayPoint) -> ScreenshotEditPoint {
        let localX = Self.clampedUnit((displayPoint.x - displayOriginX) / displayWidth)
        let localY = Self.clampedUnit((displayPoint.y - displayOriginY) / displayHeight)
        return ScreenshotEditPoint(
            x: localX * imagePixelWidth,
            y: localY * imagePixelHeight
        )
    }

    /// Maps a top-left source pixel into the full editor canvas.
    public func displayPoint(from imagePoint: ScreenshotEditPoint) -> ScreenshotEditDisplayPoint {
        let normalizedX = Self.clampedUnit(imagePoint.x / imagePixelWidth)
        let normalizedY = Self.clampedUnit(imagePoint.y / imagePixelHeight)
        return ScreenshotEditDisplayPoint(
            x: displayOriginX + normalizedX * displayWidth,
            y: displayOriginY + normalizedY * displayHeight
        )
    }

    /// Converts a source-image pixel length to the aspect-fitted display size.
    public func displayLength(fromImagePixels pixels: Double) -> Double {
        guard pixels.isFinite else { return 0 }
        let uniformScale = min(
            displayWidth / imagePixelWidth,
            displayHeight / imagePixelHeight
        )
        return max(0, pixels) * uniformScale
    }

    private static func positiveDimension(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        return value
    }

    private static func clampedUnit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public struct ScreenshotFreehandStroke: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let points: [ScreenshotEditPoint]
    public let color: ScreenshotRGBAColor
    public let lineWidth: Double

    public init(
        id: UUID = UUID(),
        points: [ScreenshotEditPoint],
        color: ScreenshotRGBAColor,
        lineWidth: Double = 4
    ) {
        self.id = id
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
    }
}

/// A brush path describing where the renderer should pixelate the image.
public struct ScreenshotMosaicStroke: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let points: [ScreenshotEditPoint]
    public let brushDiameter: Double
    public let pixelSize: Double

    public init(
        id: UUID = UUID(),
        points: [ScreenshotEditPoint],
        brushDiameter: Double = 40,
        pixelSize: Double = 12
    ) {
        self.id = id
        self.points = points
        self.brushDiameter = brushDiameter
        self.pixelSize = pixelSize
    }
}

public struct ScreenshotRectangleAnnotation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let start: ScreenshotEditPoint
    public let end: ScreenshotEditPoint
    public let color: ScreenshotRGBAColor
    public let lineWidth: Double

    public init(
        id: UUID = UUID(),
        start: ScreenshotEditPoint,
        end: ScreenshotEditPoint,
        color: ScreenshotRGBAColor,
        lineWidth: Double = 4
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.color = color
        self.lineWidth = lineWidth
    }

    public var minX: Double { min(start.x, end.x) }
    public var minY: Double { min(start.y, end.y) }
    public var maxX: Double { max(start.x, end.x) }
    public var maxY: Double { max(start.y, end.y) }
    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
}

public struct ScreenshotArrowAnnotation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let start: ScreenshotEditPoint
    public let end: ScreenshotEditPoint
    public let color: ScreenshotRGBAColor
    public let lineWidth: Double

    public init(
        id: UUID = UUID(),
        start: ScreenshotEditPoint,
        end: ScreenshotEditPoint,
        color: ScreenshotRGBAColor,
        lineWidth: Double = 4
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.color = color
        self.lineWidth = lineWidth
    }
}

/// A single-line text label anchored at its top-left corner in source pixels.
public struct ScreenshotTextAnnotation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let origin: ScreenshotEditPoint
    public let text: String
    public let color: ScreenshotRGBAColor
    public let fontSize: Double

    public init(
        id: UUID = UUID(),
        origin: ScreenshotEditPoint,
        text: String,
        color: ScreenshotRGBAColor,
        fontSize: Double = 48
    ) {
        self.id = id
        self.origin = origin
        self.text = text
        self.color = color
        self.fontSize = fontSize
    }
}

/// A numbered badge followed by an optional single-line explanation.
///
/// `origin` is the top-left corner of the badge in source pixels. Keeping the
/// number as an integer prevents malformed values from reaching the renderer;
/// the editor owns the temporary string used while the user is typing.
public struct ScreenshotSequenceAnnotation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let origin: ScreenshotEditPoint
    public let number: Int
    public let text: String
    public let color: ScreenshotRGBAColor
    public let fontSize: Double

    public init(
        id: UUID = UUID(),
        origin: ScreenshotEditPoint,
        number: Int,
        text: String = "",
        color: ScreenshotRGBAColor,
        fontSize: Double = 48
    ) {
        self.id = id
        self.origin = origin
        self.number = number
        self.text = text
        self.color = color
        self.fontSize = fontSize
    }

    public var badgeDiameter: Double {
        max(28, max(18, fontSize) * 1.35)
    }

    public var badgeFontSize: Double {
        let preferredSize = max(12, max(18, fontSize) * 0.72)
        let characterCount = Double(max(1, String(number).count))
        let estimatedWidthAtOnePoint = characterCount * 0.62
        let fittingSize = badgeDiameter * 0.76 / estimatedWidthAtOnePoint
        return max(10, min(preferredSize, fittingSize))
    }

    public var textGap: Double {
        max(8, max(18, fontSize) * 0.28)
    }
}

/// One committed, immutable screenshot edit.
public enum ScreenshotEditOperation: Identifiable, Equatable, Sendable {
    case freehand(ScreenshotFreehandStroke)
    case mosaic(ScreenshotMosaicStroke)
    case rectangle(ScreenshotRectangleAnnotation)
    case arrow(ScreenshotArrowAnnotation)
    case text(ScreenshotTextAnnotation)
    case sequence(ScreenshotSequenceAnnotation)

    public var id: UUID {
        switch self {
        case let .freehand(stroke): stroke.id
        case let .mosaic(stroke): stroke.id
        case let .rectangle(annotation): annotation.id
        case let .arrow(annotation): annotation.id
        case let .text(annotation): annotation.id
        case let .sequence(annotation): annotation.id
        }
    }

    public var tool: ScreenshotEditTool {
        switch self {
        case .freehand: .pen
        case .mosaic: .mosaic
        case .rectangle: .rectangle
        case .arrow: .arrow
        case .text: .text
        case .sequence: .sequence
        }
    }
}

/// Undo/redo history for committed screenshot edits.
///
/// Calling `commit(_:)` after an undo discards the redo branch. `reset()` is a
/// hard reset: it removes all operations and both history branches.
public struct ScreenshotEditHistory: Equatable, Sendable {
    public private(set) var operations: [ScreenshotEditOperation]
    private var redoOperations: [ScreenshotEditOperation]

    public init(operations: [ScreenshotEditOperation] = []) {
        self.operations = operations
        redoOperations = []
    }

    public var isEmpty: Bool { operations.isEmpty }
    public var canUndo: Bool { !operations.isEmpty }
    public var canRedo: Bool { !redoOperations.isEmpty }
    public var undoCount: Int { operations.count }
    public var redoCount: Int { redoOperations.count }

    public mutating func commit(_ operation: ScreenshotEditOperation) {
        operations.append(operation)
        redoOperations.removeAll(keepingCapacity: true)
    }

    @discardableResult
    public mutating func undo() -> ScreenshotEditOperation? {
        guard let operation = operations.popLast() else { return nil }
        redoOperations.append(operation)
        return operation
    }

    @discardableResult
    public mutating func redo() -> ScreenshotEditOperation? {
        guard let operation = redoOperations.popLast() else { return nil }
        operations.append(operation)
        return operation
    }

    public mutating func reset() {
        operations.removeAll(keepingCapacity: false)
        redoOperations.removeAll(keepingCapacity: false)
    }
}
