import AppKit
import CrossToolCore
import Foundation
@testable import CrossToolApp
import Testing

@MainActor
@Suite("Screenshot automatic copy")
struct ScreenshotAutomaticCopyTests {
    @Test("Pasteboard writer stores independent PNG and TIFF image data")
    func writesImageBytesToPasteboard() throws {
        let pasteboard = NSPasteboard(name: .init("crosio-screenshot-test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let pngData = try makePNGData()
        let image = try #require(NSImage(data: pngData))

        try ScreenshotPasteboardWriter(pasteboard: pasteboard).writePNG(
            pngData,
            tiffData: image.tiffRepresentation
        )

        #expect(pasteboard.data(forType: .png) == pngData)
        #expect(pasteboard.data(forType: .tiff) != nil)
        #expect(NSImage(pasteboard: pasteboard) != nil)
    }

    @Test("Text pasteboard writer stores OCR text only when explicitly called")
    func writesRecognizedTextToPasteboard() throws {
        let pasteboard = NSPasteboard(name: .init("crosio-ocr-test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }

        try ScreenshotTextPasteboardWriter(pasteboard: pasteboard)
            .writeText("中文 and English")

        #expect(pasteboard.string(forType: .string) == "中文 and English")
        #expect(pasteboard.data(forType: .png) == nil)
    }

    @Test("Automatically copied original remains delivered until annotations change")
    func tracksTheDeliveredEditRevision() throws {
        let sourceURL = try makeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let writer = RecordingScreenshotPasteboardWriter()
        let model = try ScreenshotEditorViewModel(
            sourceURL: sourceURL,
            originalWasAutomaticallyCopied: true,
            pasteboardWriter: writer,
            onSharePNG: { _ in }
        )

        #expect(model.hasDeliveredOutput)
        #expect(model.hasAnyDeliveredOutput)

        model.selectedTool = .rectangle
        model.beginInteraction(at: .init(x: 0, y: 0))
        model.endInteraction(at: .init(x: 1, y: 1))
        #expect(model.hasAnnotations)
        #expect(!model.hasDeliveredOutput)

        model.undo()
        #expect(!model.hasAnnotations)
        #expect(model.hasDeliveredOutput)

        model.beginInteraction(at: .init(x: 0, y: 0))
        model.endInteraction(at: .init(x: 1, y: 1))
        var closeCount = 0
        model.requestClose = { closeCount += 1 }
        model.copyToPasteboard()

        #expect(writer.writeCount == 1)
        #expect(model.hasDeliveredOutput)
        #expect(closeCount == 1)
    }

    @Test("A cancelled draft interaction restores the delivered original state")
    func cancellingDraftRestoresDeliveryState() throws {
        let sourceURL = try makeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let model = try ScreenshotEditorViewModel(
            sourceURL: sourceURL,
            originalWasAutomaticallyCopied: true,
            pasteboardWriter: RecordingScreenshotPasteboardWriter(),
            onSharePNG: { _ in }
        )

        model.beginInteraction(at: .init(x: 0, y: 0))
        #expect(!model.hasDeliveredOutput)
        model.cancelInteraction()
        #expect(model.hasDeliveredOutput)
    }

    @Test("Whitespace-only text is cancelled without changing history or delivery state")
    func whitespaceOnlyTextIsCancelled() throws {
        let sourceURL = try makeTemporaryPNG(width: 320, height: 180, fillColor: .white)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let model = try ScreenshotEditorViewModel(
            sourceURL: sourceURL,
            originalWasAutomaticallyCopied: true,
            pasteboardWriter: RecordingScreenshotPasteboardWriter(),
            onSharePNG: { _ in }
        )
        let originalPNG = try ScreenshotEditorRenderer.pngData(from: model.previewImage)

        model.selectTool(.text)
        model.beginTextEditing(at: .init(x: 32, y: 24))

        #expect(model.activeTextEntry?.origin == .init(x: 32, y: 24))
        #expect(model.activeTextEntry?.kind == .text)
        #expect(model.draftOperation?.tool == .text)
        #expect(!model.hasDeliveredOutput)

        model.updateActiveText(" \n\t ")
        #expect(!model.commitTextEditing())

        #expect(model.activeTextEntry == nil)
        #expect(model.draftOperation == nil)
        #expect(model.committedOperations.isEmpty)
        #expect(!model.hasAnnotations)
        #expect(!model.canUndo)
        #expect(model.hasDeliveredOutput)
        #expect(try ScreenshotEditorRenderer.pngData(from: model.previewImage) == originalPNG)
    }

    @Test("Text is one atomic operation and undo redo restore the exact rendering")
    func textCommitUndoAndRedoAreAtomic() throws {
        let sourceURL = try makeTemporaryPNG(width: 320, height: 180, fillColor: .white)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let model = try ScreenshotEditorViewModel(
            sourceURL: sourceURL,
            originalWasAutomaticallyCopied: true,
            pasteboardWriter: RecordingScreenshotPasteboardWriter(),
            onSharePNG: { _ in }
        )
        let originalPNG = try ScreenshotEditorRenderer.pngData(from: model.previewImage)

        model.selectedColor = .red
        model.textFontSize = 30
        model.selectTool(.text)
        model.beginTextEditing(at: .init(x: 24, y: 18))
        model.updateActiveText(" 说明\n文字 ")
        #expect(model.commitTextEditing())

        let committed = try #require(model.committedOperations.first)
        guard case .text(let annotation) = committed else {
            Issue.record("Expected a committed text annotation")
            return
        }
        #expect(annotation.origin == .init(x: 24, y: 18))
        #expect(annotation.text == "说明 文字")
        #expect(annotation.color == .red)
        #expect(annotation.fontSize == 30)
        #expect(model.committedOperations.count == 1)
        #expect(model.canUndo)
        #expect(!model.canRedo)
        #expect(model.hasAnnotations)
        #expect(!model.hasDeliveredOutput)

        let annotatedPNG = try ScreenshotEditorRenderer.pngData(from: model.previewImage)
        #expect(annotatedPNG != originalPNG)

        model.undo()
        #expect(model.committedOperations.isEmpty)
        #expect(!model.hasAnnotations)
        #expect(model.canRedo)
        #expect(try ScreenshotEditorRenderer.pngData(from: model.previewImage) == originalPNG)

        model.redo()
        #expect(model.committedOperations == [committed])
        #expect(try ScreenshotEditorRenderer.pngData(from: model.previewImage) == annotatedPNG)
    }

    @Test("Sequence increments, accepts manual numbers, and follows undo redo history")
    func sequenceIncrementManualNumberUndoAndRedo() throws {
        let sourceURL = try makeTemporaryPNG(width: 480, height: 240, fillColor: .white)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let model = try ScreenshotEditorViewModel(
            sourceURL: sourceURL,
            originalWasAutomaticallyCopied: true,
            pasteboardWriter: RecordingScreenshotPasteboardWriter(),
            onSharePNG: { _ in }
        )

        model.selectTool(.sequence)
        #expect(model.nextSequenceNumber == 1)

        model.beginTextEditing(at: .init(x: 20, y: 20))
        #expect(model.activeTextEntry?.resolvedNumber == 1)
        #expect(model.commitTextEditing())
        #expect(model.nextSequenceNumber == 2)

        model.beginTextEditing(at: .init(x: 120, y: 20))
        #expect(model.activeTextEntry?.resolvedNumber == 2)
        model.updateActiveSequenceNumber("编号 7")
        model.updateActiveText("第一步")
        #expect(model.activeTextEntry?.numberText == "7")
        #expect(model.commitTextEditing())
        #expect(model.nextSequenceNumber == 8)

        guard model.committedOperations.count == 2,
              case .sequence(let first) = model.committedOperations[0],
              case .sequence(let second) = model.committedOperations[1] else {
            Issue.record("Expected two committed sequence annotations")
            return
        }
        #expect(first.number == 1)
        #expect(first.text.isEmpty)
        #expect(second.number == 7)
        #expect(second.text == "第一步")

        model.beginTextEditing(at: .init(x: 240, y: 20))
        #expect(model.activeTextEntry?.resolvedNumber == 8)
        #expect(model.cancelTextEditing())
        #expect(model.nextSequenceNumber == 8)
        #expect(model.committedOperations.count == 2)

        model.undo()
        #expect(model.committedOperations.count == 1)
        #expect(model.nextSequenceNumber == 2)
        #expect(model.canRedo)

        model.redo()
        #expect(model.committedOperations.count == 2)
        #expect(model.nextSequenceNumber == 8)

        model.beginTextEditing(at: .init(x: 240, y: 20))
        model.updateActiveSequenceNumber("3")
        #expect(model.commitTextEditing())
        #expect(model.nextSequenceNumber == 4)
    }

    @Test("Right-bottom sequence stays inside the image and accepts ASCII digits only")
    func rightBottomSequenceIsClampedAndFiltersNonASCIIDigits() throws {
        let sourceURL = try makeTemporaryPNG(width: 320, height: 180, fillColor: .white)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let model = try ScreenshotEditorViewModel(
            sourceURL: sourceURL,
            pasteboardWriter: RecordingScreenshotPasteboardWriter(),
            onSharePNG: { _ in }
        )

        model.textFontSize = 48
        model.selectTool(.sequence)
        model.beginTextEditing(at: .init(x: 10_000, y: 10_000))
        model.updateActiveSequenceNumber("１２3٤")

        #expect(model.activeTextEntry?.numberText == "3")
        #expect(model.activeTextEntry?.resolvedNumber == 3)
        guard case .sequence(let oneDigit) = model.draftOperation else {
            Issue.record("Expected a sequence draft")
            return
        }
        #expect(oneDigit.origin.x >= 0)
        #expect(oneDigit.origin.y >= 0)
        #expect(oneDigit.origin.x + oneDigit.badgeDiameter <= Double(model.pixelWidth))
        #expect(oneDigit.origin.y + oneDigit.badgeDiameter <= Double(model.pixelHeight))

        model.updateActiveSequenceNumber("999999")
        #expect(model.activeTextEntry?.numberText == "999999")
        #expect(model.activeTextEntry?.resolvedNumber == 999_999)
        guard case .sequence(let sixDigits) = model.draftOperation else {
            Issue.record("Expected the updated sequence draft")
            return
        }
        #expect(sixDigits.origin.x >= 0)
        #expect(sixDigits.origin.y >= 0)
        #expect(sixDigits.origin.x + sixDigits.badgeDiameter <= Double(model.pixelWidth))
        #expect(sixDigits.origin.y + sixDigits.badgeDiameter <= Double(model.pixelHeight))

        #expect(model.commitTextEditing())
        guard case .sequence(let committed) = model.committedOperations.first else {
            Issue.record("Expected a committed sequence")
            return
        }
        #expect(committed.number == 999_999)
        #expect(committed.origin == sixDigits.origin)
    }

    @Test("Redo while editing leaves the draft and redo branch untouched")
    func redoWhileEditingDoesNotCancelDraft() throws {
        let sourceURL = try makeTemporaryPNG(width: 320, height: 180, fillColor: .white)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let model = try ScreenshotEditorViewModel(
            sourceURL: sourceURL,
            pasteboardWriter: RecordingScreenshotPasteboardWriter(),
            onSharePNG: { _ in }
        )

        model.selectTool(.sequence)
        model.beginTextEditing(at: .init(x: 20, y: 20))
        #expect(model.commitTextEditing())
        model.undo()
        #expect(model.canRedo)

        model.beginTextEditing(at: .init(x: 80, y: 40))
        model.updateActiveText("仍在输入")
        let draftBeforeRedo = model.activeTextEntry

        model.redo()

        #expect(model.activeTextEntry == draftBeforeRedo)
        #expect(model.draftOperation == draftBeforeRedo?.operation)
        #expect(model.committedOperations.isEmpty)
        #expect(model.canRedo)
    }

    @Test("Copy commits pending text and preserves the source pixel dimensions")
    func copyCommitsPendingTextAndPreservesDimensions() throws {
        let sourceURL = try makeTemporaryPNG(width: 320, height: 180, fillColor: .white)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let writer = RecordingScreenshotPasteboardWriter()
        let model = try ScreenshotEditorViewModel(
            sourceURL: sourceURL,
            originalWasAutomaticallyCopied: true,
            pasteboardWriter: writer,
            onSharePNG: { _ in }
        )
        var closeCount = 0
        model.requestClose = { closeCount += 1 }
        let originalPNG = try ScreenshotEditorRenderer.pngData(from: model.previewImage)

        model.selectTool(.text)
        model.beginTextEditing(at: .init(x: 30, y: 24))
        model.updateActiveText("输出前提交")
        #expect(model.activeTextEntry != nil)

        model.copyToPasteboard()

        #expect(model.activeTextEntry == nil)
        #expect(model.committedOperations.count == 1)
        #expect(model.hasDeliveredOutput)
        #expect(writer.writeCount == 1)
        #expect(closeCount == 1)
        let writtenPNG = try #require(writer.writtenPNGData.first)
        #expect(writtenPNG != originalPNG)
        let writtenImage = try #require(NSBitmapImageRep(data: writtenPNG))
        #expect(writtenImage.pixelsWide == 320)
        #expect(writtenImage.pixelsHigh == 180)
        let finalPreviewPNG = try ScreenshotEditorRenderer.pngData(from: model.previewImage)
        #expect(writtenPNG == finalPreviewPNG)
    }

    @Test("Renderer keeps dimensions and maps a top-left text anchor without vertical mirroring")
    func rendererKeepsDimensionsAndTopLeftCoordinates() throws {
        let sourceURL = try makeTemporaryPNG(width: 320, height: 180, fillColor: .white)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let renderer = try ScreenshotEditorRenderer(imageURL: sourceURL)
        let rendered = try renderer.render(operations: [
            .text(ScreenshotTextAnnotation(
                origin: .init(x: 20, y: 12),
                text: "TEST",
                color: .red,
                fontSize: 32
            )),
        ])

        #expect(rendered.width == 320)
        #expect(rendered.height == 180)
        let optionalChangedBounds = try changedPixelBounds(
            original: renderer.originalImage,
            rendered: rendered
        )
        let changedBounds = try #require(optionalChangedBounds)
        #expect(changedBounds.minX >= 15)
        #expect(changedBounds.minX < 40)
        // Pixel rows here follow the renderer's Core Graphics bottom-left
        // raster convention. A top-left model y of 12 must therefore land in
        // the upper half (large raster y), not be mirrored near raster y 12.
        #expect(changedBounds.minY > 100)
        #expect(changedBounds.maxY < 175)
    }

    @Test("Renderer draws a sequence badge and its description at source scale")
    func rendererDrawsSequenceBadgeAndDescription() throws {
        let sourceURL = try makeTemporaryPNG(width: 480, height: 240, fillColor: .white)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let renderer = try ScreenshotEditorRenderer(imageURL: sourceURL)
        let annotation = ScreenshotSequenceAnnotation(
            origin: .init(x: 40, y: 30),
            number: 8,
            text: "NEXT",
            color: .blue,
            fontSize: 32
        )
        let rendered = try renderer.render(operations: [.sequence(annotation)])

        #expect(rendered.width == 480)
        #expect(rendered.height == 240)
        let optionalChangedBounds = try changedPixelBounds(
            original: renderer.originalImage,
            rendered: rendered
        )
        let changedBounds = try #require(optionalChangedBounds)
        #expect(changedBounds.minX <= annotation.origin.x + 2)
        #expect(
            changedBounds.maxX
                > annotation.origin.x + annotation.badgeDiameter + annotation.textGap + 10
        )
        #expect(changedBounds.minY > 120)
        #expect(changedBounds.maxY < 230)
    }

    @Test("Failed manual copy keeps the editor open and version undelivered")
    func failedCopyDoesNotClose() throws {
        let sourceURL = try makeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let writer = RecordingScreenshotPasteboardWriter(error: ScreenshotPasteboardError.writeFailed)
        let model = try ScreenshotEditorViewModel(
            sourceURL: sourceURL,
            pasteboardWriter: writer,
            onSharePNG: { _ in }
        )
        var closeCount = 0
        model.requestClose = { closeCount += 1 }

        model.copyToPasteboard()

        #expect(writer.writeCount == 1)
        #expect(!model.hasDeliveredOutput)
        #expect(!model.hasAnyDeliveredOutput)
        #expect(closeCount == 0)
        #expect(model.statusMessage?.contains("复制失败") == true)
    }

    @Test("Pinning sends the annotated preview, delivers that revision, and closes")
    func pinningAnnotatedPreviewDeliversCurrentRevision() throws {
        let sourceURL = try makeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let originalPNG = try Data(contentsOf: sourceURL)
        var pinnedPNG: Data?
        var pinCount = 0
        var closeCount = 0
        let model = try ScreenshotEditorViewModel(
            sourceURL: sourceURL,
            originalWasAutomaticallyCopied: true,
            pasteboardWriter: RecordingScreenshotPasteboardWriter(),
            onPinImage: { image in
                pinCount += 1
                pinnedPNG = try ScreenshotEditorRenderer.pngData(from: image)
            },
            onSharePNG: { _ in }
        )
        model.requestClose = { closeCount += 1 }

        model.selectedTool = .rectangle
        model.lineWidth = 2
        model.beginInteraction(at: .init(x: 0, y: 0))
        model.endInteraction(at: .init(x: 1, y: 1))
        let annotatedPreviewPNG = try ScreenshotEditorRenderer.pngData(from: model.previewImage)

        #expect(model.hasAnnotations)
        #expect(!model.hasDeliveredOutput)
        #expect(annotatedPreviewPNG != originalPNG)

        model.pinCurrentImage()

        #expect(pinCount == 1)
        #expect(pinnedPNG == annotatedPreviewPNG)
        #expect(pinnedPNG != originalPNG)
        #expect(model.hasDeliveredOutput)
        #expect(model.hasAnyDeliveredOutput)
        #expect(closeCount == 1)
    }

    @Test("A failed pin keeps the annotated revision undelivered and the editor open")
    func failedPinDoesNotDeliverOrClose() throws {
        let sourceURL = try makeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        var pinCount = 0
        var closeCount = 0
        let model = try ScreenshotEditorViewModel(
            sourceURL: sourceURL,
            originalWasAutomaticallyCopied: true,
            pasteboardWriter: RecordingScreenshotPasteboardWriter(),
            onPinImage: { _ in
                pinCount += 1
                throw CocoaError(.fileWriteUnknown)
            },
            onSharePNG: { _ in }
        )
        model.requestClose = { closeCount += 1 }

        model.selectedTool = .rectangle
        model.beginInteraction(at: .init(x: 0, y: 0))
        model.endInteraction(at: .init(x: 1, y: 1))
        #expect(model.hasAnnotations)
        #expect(!model.hasDeliveredOutput)

        model.pinCurrentImage()

        #expect(pinCount == 1)
        #expect(!model.hasDeliveredOutput)
        #expect(model.hasAnyDeliveredOutput)
        #expect(closeCount == 0)
        #expect(model.statusMessage?.contains("创建悬浮贴图失败") == true)
    }

    @Test("OCR recognizes the original without replacing the automatically copied image")
    func recognizesTextWithoutAutomaticTextCopy() async throws {
        let sourceURL = try makeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let imageWriter = RecordingScreenshotPasteboardWriter()
        let textWriter = RecordingScreenshotTextPasteboardWriter()
        let model = try ScreenshotEditorViewModel(
            sourceURL: sourceURL,
            originalWasAutomaticallyCopied: true,
            pasteboardWriter: imageWriter,
            textRecognizer: ImmediateScreenshotTextRecognizer(text: "  第一行\nSecond line  "),
            textPasteboardWriter: textWriter,
            onSharePNG: { _ in }
        )

        model.startAutomaticTextRecognition()
        #expect(await waitUntil { model.textRecognitionState == .recognized })

        #expect(model.recognizedText == "第一行\nSecond line")
        #expect(model.recognizedCharacterCount == 15)
        #expect(model.canCopyRecognizedText)
        #expect(textWriter.writtenTexts.isEmpty)
        #expect(imageWriter.writeCount == 0)
        #expect(model.hasDeliveredOutput)
        #expect(model.hasAnyDeliveredOutput)

        var closeCount = 0
        model.requestClose = { closeCount += 1 }
        model.copyRecognizedText()

        #expect(textWriter.writtenTexts == ["第一行\nSecond line"])
        #expect(imageWriter.writeCount == 0)
        #expect(closeCount == 0)
        #expect(model.hasDeliveredOutput)
        #expect(model.textCopyMessage == "文字已复制到剪贴板")
    }

    @Test("OCR distinguishes empty output and can retry after a failure")
    func handlesEmptyFailureAndRetry() async throws {
        let sourceURL = try makeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let emptyModel = try ScreenshotEditorViewModel(
            sourceURL: sourceURL,
            textRecognizer: ImmediateScreenshotTextRecognizer(text: " \n\t "),
            textPasteboardWriter: RecordingScreenshotTextPasteboardWriter(),
            onSharePNG: { _ in }
        )
        emptyModel.startAutomaticTextRecognition()
        #expect(await waitUntil { emptyModel.textRecognitionState == .empty })
        #expect(emptyModel.recognizedText.isEmpty)
        #expect(!emptyModel.canCopyRecognizedText)

        let recognizer = SequenceScreenshotTextRecognizer(outcomes: [
            .failure("本机识别器暂时不可用"),
            .text("重试成功")
        ])
        let retryModel = try ScreenshotEditorViewModel(
            sourceURL: sourceURL,
            textRecognizer: recognizer,
            textPasteboardWriter: RecordingScreenshotTextPasteboardWriter(),
            onSharePNG: { _ in }
        )
        retryModel.startAutomaticTextRecognition()
        #expect(await waitUntil {
            retryModel.textRecognitionState == .failed("本机识别器暂时不可用")
        })

        retryModel.retryTextRecognition()
        #expect(await waitUntil { retryModel.textRecognitionState == .recognized })
        #expect(retryModel.recognizedText == "重试成功")
        #expect(await recognizer.currentCallCount() == 2)
    }

    @Test("A cancelled late OCR result cannot overwrite a newer request")
    func ignoresCancelledLateRecognitionResult() async throws {
        let sourceURL = try makeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let recognizer = ControlledScreenshotTextRecognizer()
        let model = try ScreenshotEditorViewModel(
            sourceURL: sourceURL,
            textRecognizer: recognizer,
            textPasteboardWriter: RecordingScreenshotTextPasteboardWriter(),
            onSharePNG: { _ in }
        )

        model.startAutomaticTextRecognition()
        model.startAutomaticTextRecognition()
        #expect(await waitUntil { await recognizer.currentCallCount() == 1 })

        model.retryTextRecognition()
        #expect(await waitUntil { await recognizer.currentCallCount() == 2 })
        await recognizer.complete(call: 0, with: "旧文字")
        await Task.yield()
        #expect(model.textRecognitionState == .recognizing)
        #expect(model.recognizedText.isEmpty)

        await recognizer.complete(call: 1, with: "新文字")
        #expect(await waitUntil { model.textRecognitionState == .recognized })
        #expect(model.recognizedText == "新文字")
    }

    @Test("Cancelling OCR returns to idle and ignores its eventual response")
    func cancelsRecognition() async throws {
        let sourceURL = try makeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let recognizer = ControlledScreenshotTextRecognizer()
        let model = try ScreenshotEditorViewModel(
            sourceURL: sourceURL,
            textRecognizer: recognizer,
            textPasteboardWriter: RecordingScreenshotTextPasteboardWriter(),
            onSharePNG: { _ in }
        )

        model.startAutomaticTextRecognition()
        #expect(await waitUntil { await recognizer.currentCallCount() == 1 })
        model.cancelTextRecognition()
        #expect(model.textRecognitionState == .idle)

        await recognizer.complete(call: 0, with: "不应出现")
        await Task.yield()
        #expect(model.textRecognitionState == .idle)
        #expect(model.recognizedText.isEmpty)
    }

    private func makeTemporaryPNG(
        width: Int = 2,
        height: Int = 2,
        fillColor: NSColor = .systemBlue
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crosio-screenshot-\(UUID()).png")
        try makePNGData(
            width: width,
            height: height,
            fillColor: fillColor
        ).write(to: url, options: .atomic)
        return url
    }

    private func makePNGData(
        width: Int = 2,
        height: Int = 2,
        fillColor: NSColor = .systemBlue
    ) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(fillColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try ScreenshotEditorRenderer.pngData(from: #require(context.makeImage()))
    }

    private func changedPixelBounds(
        original: CGImage,
        rendered: CGImage
    ) throws -> CGRect? {
        #expect(original.width == rendered.width)
        #expect(original.height == rendered.height)
        let width = original.width
        let height = original.height
        let originalPixels = try rgbaPixels(from: original)
        let renderedPixels = try rgbaPixels(from: rendered)
        var minimumX = width
        var minimumY = height
        var maximumX = -1
        var maximumY = -1

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let isDifferent = (0..<4).contains { channel in
                    abs(
                        Int(originalPixels[offset + channel])
                            - Int(renderedPixels[offset + channel])
                    ) > 2
                }
                guard isDifferent else { continue }
                minimumX = min(minimumX, x)
                minimumY = min(minimumY, y)
                maximumX = max(maximumX, x)
                maximumY = max(maximumY, y)
            }
        }

        guard maximumX >= minimumX, maximumY >= minimumY else { return nil }
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX + 1,
            height: maximumY - minimumY + 1
        )
    }

    private func rgbaPixels(from image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let createdContext = pixels.withUnsafeMutableBytes { buffer -> CGContext? in
            CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }
        let context = try #require(createdContext)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }
}

@MainActor
private final class RecordingScreenshotPasteboardWriter: ScreenshotPasteboardWriting {
    private(set) var writeCount = 0
    private(set) var writtenPNGData: [Data] = []
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func writePNG(_ pngData: Data, tiffData: Data?) throws {
        writeCount += 1
        if let error { throw error }
        writtenPNGData.append(pngData)
    }
}

private struct ImmediateScreenshotTextRecognizer: ScreenshotTextRecognizing {
    let text: String

    func recognizeText(in image: CGImage) async throws -> String {
        text
    }
}

private actor SequenceScreenshotTextRecognizer: ScreenshotTextRecognizing {
    enum Outcome: Sendable {
        case text(String)
        case failure(String)
    }

    private var outcomes: [Outcome]
    private var callCount = 0

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func recognizeText(in image: CGImage) async throws -> String {
        let index = callCount
        callCount += 1
        let outcome = outcomes[min(index, outcomes.count - 1)]
        switch outcome {
        case .text(let text):
            return text
        case .failure(let message):
            throw ScreenshotTextRecognizerTestError(message: message)
        }
    }

    func currentCallCount() -> Int {
        callCount
    }
}

private actor ControlledScreenshotTextRecognizer: ScreenshotTextRecognizing {
    private var callCount = 0
    private var continuations: [Int: CheckedContinuation<String, Error>] = [:]

    func recognizeText(in image: CGImage) async throws -> String {
        let call = callCount
        callCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations[call] = continuation
        }
    }

    func currentCallCount() -> Int {
        callCount
    }

    func complete(call: Int, with text: String) {
        continuations.removeValue(forKey: call)?.resume(returning: text)
    }
}

private struct ScreenshotTextRecognizerTestError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

@MainActor
private final class RecordingScreenshotTextPasteboardWriter: ScreenshotTextPasteboardWriting {
    private(set) var writtenTexts: [String] = []
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func writeText(_ text: String) throws {
        if let error { throw error }
        writtenTexts.append(text)
    }
}
