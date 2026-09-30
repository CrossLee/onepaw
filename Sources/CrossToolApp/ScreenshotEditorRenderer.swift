import AppKit
import CoreText
import CoreImage
import CoreImage.CIFilterBuiltins
import CrossToolCore
import Foundation
import ImageIO

private let screenshotEditorMaximumPixelCount = 50_000_000

enum ScreenshotEditorRenderError: LocalizedError {
    case unreadableImage
    case unsupportedImageSize
    case bitmapCreationFailed
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "无法读取这张截图"
        case .unsupportedImageSize:
            return "截图尺寸无效或过大"
        case .bitmapCreationFailed:
            return "无法创建图片画布"
        case .pngEncodingFailed:
            return "无法生成 PNG 图片"
        }
    }
}

struct ScreenshotEditorImageMetadata: Equatable, Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
}

/// `CGImage` instances are immutable and Core Graphics permits them to be used
/// across threads. The SDK does not currently declare that contract as
/// `Sendable`, so keep the unchecked boundary in this small value wrapper.
struct ScreenshotEditorDecodedImage: @unchecked Sendable {
    let image: CGImage
}

/// ImageIO does not expose mid-decode cancellation. Serializing full screenshot
/// decodes prevents a close-and-recapture sequence from piling several large
/// HDR images onto the global executor. Cancellation is checked both before
/// and after the unavoidable synchronous ImageIO call, so queued or completed
/// work is discarded promptly.
private actor ScreenshotEditorImageDecodeQueue {
    func decode(at imageURL: URL) throws -> ScreenshotEditorDecodedImage {
        try Task.checkCancellation()
        let decodedImage = try ScreenshotEditorRenderer.decodeImageSynchronously(
            at: imageURL
        )
        try Task.checkCancellation()
        return decodedImage
    }
}

private let screenshotEditorImageDecodeQueue = ScreenshotEditorImageDecodeQueue()

@MainActor
final class ScreenshotEditorRenderer {
    let originalImage: CGImage
    let pixelWidth: Int
    let pixelHeight: Int

    private lazy var ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: false
    ])
    // Keep only one full-resolution mosaic. A 6K image can consume tens of
    // megabytes, so caching every slider step would quickly exhaust memory.
    private var cachedMosaic: (pixelSize: Int, image: CGImage)?

    convenience init(imageURL: URL) throws {
        try self.init(decodedImage: Self.decodeImageSynchronously(at: imageURL))
    }

    init(decodedImage: ScreenshotEditorDecodedImage) throws {
        let image = decodedImage.image
        try Self.validate(pixelWidth: image.width, pixelHeight: image.height)

        originalImage = image
        pixelWidth = image.width
        pixelHeight = image.height
    }

    nonisolated static func imageMetadata(at imageURL: URL) throws -> ScreenshotEditorImageMetadata {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ] as CFDictionary),
        let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
        let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw ScreenshotEditorRenderError.unreadableImage
        }

        let metadata = ScreenshotEditorImageMetadata(
            pixelWidth: width.intValue,
            pixelHeight: height.intValue
        )
        try validate(
            pixelWidth: metadata.pixelWidth,
            pixelHeight: metadata.pixelHeight
        )
        return metadata
    }

    nonisolated static func decodeImage(at imageURL: URL) async throws -> ScreenshotEditorDecodedImage {
        try await screenshotEditorImageDecodeQueue.decode(at: imageURL)
    }

    nonisolated fileprivate static func decodeImageSynchronously(
        at imageURL: URL
    ) throws -> ScreenshotEditorDecodedImage {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
        let image = CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false
        ] as CFDictionary) else {
            throw ScreenshotEditorRenderError.unreadableImage
        }
        try validate(pixelWidth: image.width, pixelHeight: image.height)
        return ScreenshotEditorDecodedImage(image: image)
    }

    nonisolated private static func validate(
        pixelWidth: Int,
        pixelHeight: Int
    ) throws {
        guard pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= 32_768, pixelHeight <= 32_768,
              pixelWidth * pixelHeight <= screenshotEditorMaximumPixelCount else {
            throw ScreenshotEditorRenderError.unsupportedImageSize
        }
    }

    func render(operations: [ScreenshotEditOperation]) throws -> CGImage {
        guard let context = makeBitmapContext() else {
            throw ScreenshotEditorRenderError.bitmapCreationFailed
        }

        let bounds = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        context.interpolationQuality = .high
        context.draw(originalImage, in: bounds)

        for operation in operations {
            context.saveGState()
            switch operation {
            case .freehand(let stroke):
                drawFreehand(stroke, in: context)
            case .mosaic(let stroke):
                try drawMosaic(stroke, in: context, bounds: bounds)
            case .rectangle(let annotation):
                drawRectangle(annotation, in: context)
            case .arrow(let annotation):
                drawArrow(annotation, in: context)
            case .text(let annotation):
                drawText(annotation, in: context)
            case .sequence(let annotation):
                drawSequence(annotation, in: context)
            }
            context.restoreGState()
        }

        guard let image = context.makeImage() else {
            throw ScreenshotEditorRenderError.bitmapCreationFailed
        }
        return image
    }

    func mosaicImage(pixelSize: Double) throws -> CGImage {
        let normalizedSize = max(4, min(80, Int(pixelSize.rounded())))
        if let cachedMosaic, cachedMosaic.pixelSize == normalizedSize {
            return cachedMosaic.image
        }

        let input = CIImage(cgImage: originalImage)
        let filter = CIFilter.pixellate()
        filter.inputImage = input
        filter.scale = Float(normalizedSize)
        filter.center = CGPoint(x: input.extent.midX, y: input.extent.midY)

        guard let output = filter.outputImage?.cropped(to: input.extent),
              let image = ciContext.createCGImage(output, from: input.extent) else {
            throw ScreenshotEditorRenderError.bitmapCreationFailed
        }
        cachedMosaic = (normalizedSize, image)
        return image
    }

    static func pngData(from image: CGImage) throws -> Data {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw ScreenshotEditorRenderError.pngEncodingFailed
        }
        return data
    }

    private func makeBitmapContext() -> CGContext? {
        let colorSpace = originalImage.colorSpace
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private func drawFreehand(_ stroke: ScreenshotFreehandStroke, in context: CGContext) {
        guard let first = stroke.points.first else { return }
        context.setStrokeColor(stroke.color.cgColor)
        context.setFillColor(stroke.color.cgColor)
        context.setLineWidth(CGFloat(max(1, stroke.lineWidth)))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        if stroke.points.count == 1 {
            let point = canvasPoint(first)
            let radius = CGFloat(max(1, stroke.lineWidth)) / 2
            context.fillEllipse(in: CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            return
        }

        context.beginPath()
        context.move(to: canvasPoint(first))
        for point in stroke.points.dropFirst() {
            context.addLine(to: canvasPoint(point))
        }
        context.strokePath()
    }

    private func drawMosaic(
        _ stroke: ScreenshotMosaicStroke,
        in context: CGContext,
        bounds: CGRect
    ) throws {
        guard let first = stroke.points.first else { return }
        let diameter = CGFloat(max(2, stroke.brushDiameter))

        if stroke.points.count == 1 {
            let point = canvasPoint(first)
            context.addEllipse(in: CGRect(
                x: point.x - diameter / 2,
                y: point.y - diameter / 2,
                width: diameter,
                height: diameter
            ))
            context.clip()
        } else {
            context.beginPath()
            context.move(to: canvasPoint(first))
            for point in stroke.points.dropFirst() {
                context.addLine(to: canvasPoint(point))
            }
            context.setLineWidth(diameter)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.replacePathWithStrokedPath()
            context.clip()
        }

        context.interpolationQuality = .none
        context.draw(try mosaicImage(pixelSize: stroke.pixelSize), in: bounds)
    }

    private func drawRectangle(_ annotation: ScreenshotRectangleAnnotation, in context: CGContext) {
        context.setStrokeColor(annotation.color.cgColor)
        context.setLineWidth(CGFloat(max(1, annotation.lineWidth)))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.stroke(rect(from: annotation.start, to: annotation.end))
    }

    private func drawArrow(_ annotation: ScreenshotArrowAnnotation, in context: CGContext) {
        let start = canvasPoint(annotation.start)
        let end = canvasPoint(annotation.end)
        let lineWidth = CGFloat(max(1, annotation.lineWidth))
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length >= 1 else { return }

        let headLength = min(max(lineWidth * 4.5, 12), max(12, length * 0.36))
        let angle = atan2(dy, dx)
        let spread = CGFloat.pi / 6
        let left = CGPoint(
            x: end.x - headLength * cos(angle - spread),
            y: end.y - headLength * sin(angle - spread)
        )
        let right = CGPoint(
            x: end.x - headLength * cos(angle + spread),
            y: end.y - headLength * sin(angle + spread)
        )

        context.setStrokeColor(annotation.color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.beginPath()
        context.move(to: start)
        context.addLine(to: end)
        context.move(to: left)
        context.addLine(to: end)
        context.addLine(to: right)
        context.strokePath()
    }

    private func drawText(_ annotation: ScreenshotTextAnnotation, in context: CGContext) {
        let text = annotation.text.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return }
        let metrics = textLine(
            text,
            fontSize: annotation.fontSize,
            color: annotation.color,
            weight: .medium
        )
        let topY = Double(pixelHeight) - annotation.origin.y
        context.textMatrix = .identity
        context.textPosition = CGPoint(
            x: annotation.origin.x,
            y: topY - metrics.ascent
        )
        CTLineDraw(metrics.line, context)
    }

    private func drawSequence(
        _ annotation: ScreenshotSequenceAnnotation,
        in context: CGContext
    ) {
        let diameter = max(1, annotation.badgeDiameter)
        let topY = Double(pixelHeight) - annotation.origin.y
        let badgeRect = CGRect(
            x: annotation.origin.x,
            y: topY - diameter,
            width: diameter,
            height: diameter
        )
        context.setFillColor(annotation.color.cgColor)
        context.fillEllipse(in: badgeRect)

        let numberColor = annotation.color.contrastingTextColor
        let number = textLine(
            String(annotation.number),
            fontSize: annotation.badgeFontSize,
            color: numberColor,
            weight: .bold
        )
        context.textMatrix = .identity
        context.textPosition = CGPoint(
            x: badgeRect.midX - number.width / 2,
            y: badgeRect.minY
                + (diameter - number.ascent - number.descent) / 2
                + number.descent
        )
        CTLineDraw(number.line, context)

        let text = annotation.text.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return }
        let description = textLine(
            text,
            fontSize: annotation.fontSize,
            color: annotation.color,
            weight: .medium
        )
        context.textPosition = CGPoint(
            x: badgeRect.maxX + annotation.textGap,
            y: badgeRect.minY
                + (diameter - description.ascent - description.descent) / 2
                + description.descent
        )
        CTLineDraw(description.line, context)
    }

    private func textLine(
        _ text: String,
        fontSize: Double,
        color: ScreenshotRGBAColor,
        weight: NSFont.Weight
    ) -> (line: CTLine, width: Double, ascent: Double, descent: Double) {
        let font = NSFont.systemFont(
            ofSize: CGFloat(min(max(fontSize, 8), 512)),
            weight: weight
        )
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color.nsColor,
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(
            line,
            &ascent,
            &descent,
            nil
        )
        return (line, width, ascent, descent)
    }

    private func canvasPoint(_ point: ScreenshotEditPoint) -> CGPoint {
        CGPoint(x: point.x, y: Double(pixelHeight) - point.y)
    }

    private func rect(from start: ScreenshotEditPoint, to end: ScreenshotEditPoint) -> CGRect {
        let first = canvasPoint(start)
        let second = canvasPoint(end)
        return CGRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(second.x - first.x),
            height: abs(second.y - first.y)
        )
    }
}

private extension ScreenshotRGBAColor {
    var cgColor: CGColor {
        CGColor(
            red: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        )
    }

    var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        )
    }

    var contrastingTextColor: ScreenshotRGBAColor {
        let luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722
        return luminance > 0.58 ? .black : .white
    }
}
