import AppKit
import CrossToolCore
import Foundation
import UniformTypeIdentifiers

struct ScreenshotTextEditingDraft: Identifiable, Equatable {
    enum Kind: Equatable {
        case text
        case sequence
    }

    let id: UUID
    let kind: Kind
    let requestedOrigin: ScreenshotEditPoint
    var origin: ScreenshotEditPoint
    let fallbackNumber: Int
    var numberText: String
    var text: String
    var color: ScreenshotRGBAColor
    var fontSize: Double

    var resolvedNumber: Int {
        Int(numberText) ?? fallbackNumber
    }

    var operation: ScreenshotEditOperation {
        switch kind {
        case .text:
            return .text(ScreenshotTextAnnotation(
                id: id,
                origin: origin,
                text: text,
                color: color,
                fontSize: fontSize
            ))
        case .sequence:
            return .sequence(ScreenshotSequenceAnnotation(
                id: id,
                origin: origin,
                number: resolvedNumber,
                text: text,
                color: color,
                fontSize: fontSize
            ))
        }
    }
}

@MainActor
final class ScreenshotEditorViewModel: ObservableObject {
    typealias ShareHandler = @MainActor (Data) throws -> Void
    typealias PinHandler = @MainActor (CGImage) throws -> Void

    @Published var selectedTool: ScreenshotEditTool = .pen
    @Published var selectedColor = ScreenshotRGBAColor(red: 0.96, green: 0.19, blue: 0.23) {
        didSet { refreshActiveTextStyle() }
    }
    @Published var lineWidth: Double = 8
    @Published var mosaicBrushDiameter: Double = 48
    @Published var mosaicPixelSize: Double = 18
    @Published var textFontSize: Double = 48 {
        didSet { refreshActiveTextStyle() }
    }

    @Published private(set) var previewImage: CGImage
    /// Generated lazily when the user first paints with the mosaic tool.
    /// Long screenshots can be tens of megapixels; eagerly allocating a
    /// second full-resolution bitmap would make merely opening them costly.
    @Published private(set) var mosaicPreviewImage: CGImage?
    @Published private(set) var draftOperation: ScreenshotEditOperation?
    @Published private(set) var activeTextEntry: ScreenshotTextEditingDraft?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var hasAnnotations = false
    @Published private(set) var hasDeliveredOutput = false
    private(set) var hasAnyDeliveredOutput = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var textRecognitionState: ScreenshotTextRecognitionState = .idle
    @Published private(set) var recognizedText = ""
    @Published private(set) var textCopyMessage: String?

    let pixelWidth: Int
    let pixelHeight: Int

    var requestClose: (() -> Void)?
    weak var presentingWindow: NSWindow?

    private let sourceURL: URL
    private let renderer: ScreenshotEditorRenderer
    private let onSharePNG: ShareHandler
    private let onPinImage: PinHandler?
    private let pasteboardWriter: any ScreenshotPasteboardWriting
    private let textRecognizer: any ScreenshotTextRecognizing
    private let textPasteboardWriter: any ScreenshotTextPasteboardWriting
    private let textRecognitionImage: CGImage
    private var history = ScreenshotEditHistory()
    private var deliveredOperations: [ScreenshotEditOperation]?
    private var textRecognitionTask: Task<Void, Never>?
    private var textRecognitionRequestID: UUID?

    init(
        sourceURL: URL,
        originalWasAutomaticallyCopied: Bool = false,
        pasteboardWriter: (any ScreenshotPasteboardWriting)? = nil,
        textRecognizer: (any ScreenshotTextRecognizing)? = nil,
        textPasteboardWriter: (any ScreenshotTextPasteboardWriting)? = nil,
        onPinImage: PinHandler? = nil,
        onSharePNG: @escaping ShareHandler
    ) throws {
        let renderer = try ScreenshotEditorRenderer(imageURL: sourceURL)
        self.sourceURL = sourceURL
        self.renderer = renderer
        self.onSharePNG = onSharePNG
        self.onPinImage = onPinImage
        self.pasteboardWriter = pasteboardWriter ?? ScreenshotPasteboardWriter()
        self.textRecognizer = textRecognizer ?? VisionScreenshotTextRecognizer()
        self.textPasteboardWriter = textPasteboardWriter ?? ScreenshotTextPasteboardWriter()
        self.textRecognitionImage = renderer.originalImage
        self.previewImage = renderer.originalImage
        self.mosaicPreviewImage = nil
        self.pixelWidth = renderer.pixelWidth
        self.pixelHeight = renderer.pixelHeight
        if originalWasAutomaticallyCopied {
            deliveredOperations = []
            hasAnyDeliveredOutput = true
            hasDeliveredOutput = true
        }
    }

    var recognizedCharacterCount: Int {
        recognizedText.count
    }

    var canCopyRecognizedText: Bool {
        textRecognitionState == .recognized && !recognizedText.isEmpty
    }

    func startAutomaticTextRecognition() {
        guard textRecognitionState == .idle else { return }
        beginTextRecognition()
    }

    func retryTextRecognition() {
        beginTextRecognition()
    }

    func cancelTextRecognition() {
        textRecognitionRequestID = nil
        textRecognitionTask?.cancel()
        textRecognitionTask = nil
        if textRecognitionState == .recognizing {
            textRecognitionState = .idle
        }
    }

    func copyRecognizedText() {
        guard canCopyRecognizedText else { return }
        do {
            try textPasteboardWriter.writeText(recognizedText)
            textCopyMessage = "文字已复制到剪贴板"
        } catch {
            textCopyMessage = "复制文字失败：\(error.localizedDescription)"
        }
    }

    func beginInteraction(at point: ScreenshotEditPoint) {
        statusMessage = nil
        switch selectedTool {
        case .pen:
            draftOperation = .freehand(ScreenshotFreehandStroke(
                points: [point],
                color: selectedColor,
                lineWidth: lineWidth
            ))
        case .mosaic:
            prepareMosaicPreviewIfNeeded()
            draftOperation = .mosaic(ScreenshotMosaicStroke(
                points: [point],
                brushDiameter: mosaicBrushDiameter,
                pixelSize: mosaicPixelSize
            ))
        case .rectangle:
            draftOperation = .rectangle(ScreenshotRectangleAnnotation(
                start: point,
                end: point,
                color: selectedColor,
                lineWidth: lineWidth
            ))
        case .arrow:
            draftOperation = .arrow(ScreenshotArrowAnnotation(
                start: point,
                end: point,
                color: selectedColor,
                lineWidth: lineWidth
            ))
        case .text, .sequence:
            beginTextEditing(at: point)
            return
        }
        refreshDeliveryState()
    }

    func updateInteraction(to point: ScreenshotEditPoint) {
        updateInteraction(to: point, forceTerminalPoint: false)
    }

    private func updateInteraction(
        to point: ScreenshotEditPoint,
        forceTerminalPoint: Bool
    ) {
        guard activeTextEntry == nil else { return }
        guard let draftOperation else { return }
        switch draftOperation {
        case .freehand(let stroke):
            guard stroke.points.last != point,
                  forceTerminalPoint || shouldAppend(
                      point,
                      after: stroke.points.last,
                      minimumDistance: max(0.8, stroke.lineWidth / 5)
                  ) else {
                return
            }
            self.draftOperation = .freehand(ScreenshotFreehandStroke(
                id: stroke.id,
                points: stroke.points + [point],
                color: stroke.color,
                lineWidth: stroke.lineWidth
            ))
        case .mosaic(let stroke):
            guard stroke.points.last != point,
                  forceTerminalPoint || shouldAppend(
                      point,
                      after: stroke.points.last,
                      minimumDistance: max(1.5, stroke.brushDiameter / 8)
                  ) else {
                return
            }
            self.draftOperation = .mosaic(ScreenshotMosaicStroke(
                id: stroke.id,
                points: stroke.points + [point],
                brushDiameter: stroke.brushDiameter,
                pixelSize: stroke.pixelSize
            ))
        case .rectangle(let annotation):
            self.draftOperation = .rectangle(ScreenshotRectangleAnnotation(
                id: annotation.id,
                start: annotation.start,
                end: point,
                color: annotation.color,
                lineWidth: annotation.lineWidth
            ))
        case .arrow(let annotation):
            self.draftOperation = .arrow(ScreenshotArrowAnnotation(
                id: annotation.id,
                start: annotation.start,
                end: point,
                color: annotation.color,
                lineWidth: annotation.lineWidth
            ))
        case .text, .sequence:
            return
        }
    }

    func endInteraction(at point: ScreenshotEditPoint) {
        guard activeTextEntry == nil else { return }
        // Sampling thresholds keep long drags efficient, but the terminal
        // point must still land exactly under the pointer for pen and mosaic.
        updateInteraction(to: point, forceTerminalPoint: true)
        guard let operation = draftOperation else { return }
        draftOperation = nil

        guard isMeaningful(operation) else {
            refreshDeliveryState()
            return
        }
        history.commit(operation)
        rebuildPreview()
    }

    func cancelInteraction() {
        cancelTextEditing()
        draftOperation = nil
        refreshDeliveryState()
    }

    func selectTool(_ tool: ScreenshotEditTool) {
        if activeTextEntry != nil {
            _ = commitTextEditing()
        } else {
            draftOperation = nil
            refreshDeliveryState()
        }
        selectedTool = tool
    }

    func beginTextEditing(at point: ScreenshotEditPoint) {
        guard selectedTool == .text || selectedTool == .sequence else { return }
        if activeTextEntry != nil {
            _ = commitTextEditing()
        }

        let nextNumber = nextSequenceNumber
        let kind: ScreenshotTextEditingDraft.Kind = selectedTool == .sequence
            ? .sequence
            : .text
        activeTextEntry = ScreenshotTextEditingDraft(
            id: UUID(),
            kind: kind,
            requestedOrigin: point,
            origin: clampedTextOrigin(
                point,
                kind: kind,
                number: nextNumber,
                fontSize: textFontSize
            ),
            fallbackNumber: nextNumber,
            numberText: String(nextNumber),
            text: "",
            color: selectedColor,
            fontSize: textFontSize
        )
        rebuildActiveTextDraft()
        statusMessage = selectedTool == .sequence
            ? "已创建序号 \(nextNumber)，可继续输入说明"
            : "请输入文字，按 Return 完成"
    }

    func updateActiveText(_ value: String) {
        guard var entry = activeTextEntry else { return }
        entry.text = Self.normalizedSingleLine(value, maximumCharacters: 500)
        activeTextEntry = entry
        rebuildActiveTextDraft()
    }

    func updateActiveSequenceNumber(_ value: String) {
        guard var entry = activeTextEntry, entry.kind == .sequence else { return }
        let digits = value.filter { character in
            guard character.unicodeScalars.count == 1,
                  let scalar = character.unicodeScalars.first else {
                return false
            }
            return (48...57).contains(scalar.value)
        }
        entry.numberText = String(digits.prefix(6))
        entry.origin = clampedTextOrigin(
            entry.requestedOrigin,
            kind: entry.kind,
            number: entry.resolvedNumber,
            fontSize: entry.fontSize
        )
        activeTextEntry = entry
        rebuildActiveTextDraft()
    }

    @discardableResult
    func commitTextEditing() -> Bool {
        guard var entry = activeTextEntry else { return false }
        activeTextEntry = nil
        draftOperation = nil

        entry.text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if entry.kind == .text, entry.text.isEmpty {
            statusMessage = nil
            refreshDeliveryState()
            return false
        }

        if entry.kind == .sequence {
            let number = min(max(entry.resolvedNumber, 1), 999_999)
            entry.numberText = String(number)
        }
        history.commit(entry.operation)
        rebuildPreview()
        statusMessage = entry.kind == .sequence
            ? "已添加序号 \(entry.resolvedNumber)"
            : "已添加文字"
        return true
    }

    @discardableResult
    func cancelTextEditing() -> Bool {
        guard activeTextEntry != nil else { return false }
        activeTextEntry = nil
        draftOperation = nil
        statusMessage = nil
        refreshDeliveryState()
        return true
    }

    var nextSequenceNumber: Int {
        for operation in history.operations.reversed() {
            if case .sequence(let annotation) = operation {
                guard annotation.number < 999_999 else { return 999_999 }
                return max(annotation.number + 1, 1)
            }
        }
        return 1
    }

    var committedOperations: [ScreenshotEditOperation] {
        history.operations
    }

    func undo() {
        if cancelTextEditing() { return }
        draftOperation = nil
        guard history.undo() != nil else { return }
        rebuildPreview()
    }

    func redo() {
        guard activeTextEntry == nil else { return }
        draftOperation = nil
        guard history.redo() != nil else { return }
        rebuildPreview()
    }

    func clearAnnotations() {
        _ = cancelTextEditing()
        guard !history.operations.isEmpty else { return }
        draftOperation = nil
        history.reset()
        rebuildPreview()
        statusMessage = "已清空全部标注"
    }

    func chooseMosaicPixelSize(_ value: Double) {
        mosaicPixelSize = value
        guard selectedTool == .mosaic || mosaicPreviewImage != nil else { return }
        do {
            mosaicPreviewImage = try renderer.mosaicImage(pixelSize: value)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func copyToPasteboard() {
        _ = commitTextEditing()
        do {
            let data = try ScreenshotEditorRenderer.pngData(from: previewImage)
            let image = NSImage(
                cgImage: previewImage,
                size: NSSize(width: pixelWidth, height: pixelHeight)
            )
            try pasteboardWriter.writePNG(data, tiffData: image.tiffRepresentation)
            markCurrentVersionDelivered()
            requestClose?()
        } catch {
            statusMessage = "复制失败：\(error.localizedDescription)"
        }
    }

    func pinCurrentImage() {
        _ = commitTextEditing()
        draftOperation = nil
        refreshDeliveryState()
        guard let onPinImage else {
            statusMessage = "当前无法创建悬浮贴图"
            return
        }

        do {
            try onPinImage(previewImage)
            markCurrentVersionDelivered()
            requestClose?()
        } catch {
            statusMessage = "创建悬浮贴图失败：\(error.localizedDescription)"
        }
    }

    func saveAsPNG() {
        _ = commitTextEditing()
        let panel = NSSavePanel()
        panel.title = "保存截图"
        panel.nameFieldLabel = "文件名："
        panel.prompt = "保存"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedFilename

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                self?.writePNG(to: url, successMessage: "截图已保存")
            }
        }
        if let presentingWindow {
            panel.beginSheetModal(for: presentingWindow, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func addToShare() {
        _ = commitTextEditing()
        do {
            let data = try ScreenshotEditorRenderer.pngData(from: previewImage)
            try onSharePNG(data)
            markCurrentVersionDelivered()
            requestClose?()
        } catch {
            statusMessage = "加入共享区失败：\(error.localizedDescription)"
        }
    }

    private func beginTextRecognition() {
        textRecognitionRequestID = nil
        textRecognitionTask?.cancel()

        let requestID = UUID()
        let recognizer = textRecognizer
        let image = textRecognitionImage
        textRecognitionRequestID = requestID
        recognizedText = ""
        textCopyMessage = nil
        textRecognitionState = .recognizing

        textRecognitionTask = Task { [weak self, recognizer, image] in
            let result: Result<String, Error>
            do {
                result = .success(try await recognizer.recognizeText(in: image))
            } catch {
                result = .failure(error)
            }

            guard !Task.isCancelled, let self else { return }
            self.applyTextRecognitionResult(result, requestID: requestID)
        }
    }

    private func applyTextRecognitionResult(
        _ result: Result<String, Error>,
        requestID: UUID
    ) {
        guard textRecognitionRequestID == requestID else { return }
        textRecognitionRequestID = nil
        textRecognitionTask = nil

        switch result {
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            recognizedText = trimmed
            textRecognitionState = trimmed.isEmpty ? .empty : .recognized
        case .failure(let error):
            if error is CancellationError {
                textRecognitionState = .idle
            } else {
                recognizedText = ""
                textRecognitionState = .failed(error.localizedDescription)
            }
        }
    }

    private func writePNG(to url: URL, successMessage: String) {
        do {
            let data = try ScreenshotEditorRenderer.pngData(from: previewImage)
            try data.write(to: url, options: .atomic)
            markCurrentVersionDelivered()
            statusMessage = successMessage
            requestClose?()
        } catch {
            statusMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private func rebuildPreview() {
        do {
            previewImage = try renderer.render(operations: history.operations)
            publishHistoryState()
        } catch {
            statusMessage = "无法应用标注：\(error.localizedDescription)"
        }
    }

    private func prepareMosaicPreviewIfNeeded() {
        guard mosaicPreviewImage == nil else { return }
        do {
            mosaicPreviewImage = try renderer.mosaicImage(pixelSize: mosaicPixelSize)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func publishHistoryState() {
        canUndo = history.canUndo
        canRedo = history.canRedo
        hasAnnotations = !history.operations.isEmpty
        refreshDeliveryState()
    }

    private func markCurrentVersionDelivered() {
        deliveredOperations = history.operations
        hasAnyDeliveredOutput = true
        refreshDeliveryState()
    }

    private func refreshDeliveryState() {
        hasDeliveredOutput = draftOperation == nil
            && activeTextEntry == nil
            && deliveredOperations == history.operations
    }

    private var suggestedFilename: String {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        return "\(base)-已编辑.png"
    }

    private func shouldAppend(
        _ point: ScreenshotEditPoint,
        after previous: ScreenshotEditPoint?,
        minimumDistance: Double
    ) -> Bool {
        guard let previous else { return true }
        return hypot(point.x - previous.x, point.y - previous.y) >= minimumDistance
    }

    private func isMeaningful(_ operation: ScreenshotEditOperation) -> Bool {
        switch operation {
        case .freehand(let stroke):
            return !stroke.points.isEmpty
        case .mosaic(let stroke):
            return !stroke.points.isEmpty
        case .rectangle(let annotation):
            return abs(annotation.end.x - annotation.start.x) >= 1
                || abs(annotation.end.y - annotation.start.y) >= 1
        case .arrow(let annotation):
            return hypot(
                annotation.end.x - annotation.start.x,
                annotation.end.y - annotation.start.y
            ) >= 1
        case .text(let annotation):
            return !annotation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .sequence:
            return true
        }
    }

    private func refreshActiveTextStyle() {
        guard var entry = activeTextEntry else { return }
        entry.color = selectedColor
        entry.fontSize = textFontSize
        entry.origin = clampedTextOrigin(
            entry.requestedOrigin,
            kind: entry.kind,
            number: entry.resolvedNumber,
            fontSize: entry.fontSize
        )
        activeTextEntry = entry
        rebuildActiveTextDraft()
    }

    private func rebuildActiveTextDraft() {
        guard let activeTextEntry else { return }
        draftOperation = activeTextEntry.operation
        refreshDeliveryState()
    }

    private func clampedTextOrigin(
        _ point: ScreenshotEditPoint,
        kind: ScreenshotTextEditingDraft.Kind,
        number: Int,
        fontSize: Double
    ) -> ScreenshotEditPoint {
        let markerWidth: Double
        let markerHeight: Double
        switch kind {
        case .text:
            // Keep at least the first glyph visible when the user clicks the
            // right or bottom image edge. Longer labels may still be clipped
            // naturally by the source image bounds.
            markerWidth = max(12, fontSize * 0.7)
            markerHeight = max(18, fontSize * 1.2)
        case .sequence:
            let annotation = ScreenshotSequenceAnnotation(
                origin: point,
                number: number,
                color: selectedColor,
                fontSize: fontSize
            )
            markerWidth = annotation.badgeDiameter
            markerHeight = annotation.badgeDiameter
        }

        return ScreenshotEditPoint(
            x: min(max(point.x, 0), max(0, Double(pixelWidth) - markerWidth)),
            y: min(max(point.y, 0), max(0, Double(pixelHeight) - markerHeight))
        )
    }

    private static func normalizedSingleLine(
        _ value: String,
        maximumCharacters: Int
    ) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return String(normalized.prefix(maximumCharacters))
    }
}
