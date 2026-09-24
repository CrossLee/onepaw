import AppKit
import CrossToolCore
import SwiftUI

struct ScreenshotEditorView: View {
    @ObservedObject var model: ScreenshotEditorViewModel

    var body: some View {
        VStack(spacing: 0) {
            editorToolbar
            Divider()
            HStack(spacing: 0) {
                ScreenshotEditorCanvas(model: model)
                Divider()
                textRecognitionInspector
                    .frame(width: 300)
            }
            Divider()
            footer
        }
        .frame(minWidth: 880, minHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            model.startAutomaticTextRecognition()
        }
    }

    private var textRecognitionInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.crossToolAccent)
                Text("自动 OCR")
                    .font(.headline)
                Spacer()
                Text("本机")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.crossToolAccent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.crossToolAccent.opacity(0.12), in: Capsule())
            }

            Text("由 Mac 在本机识别原图，不上传截图")
                .font(.caption)
                .foregroundStyle(.secondary)

            Group {
                switch model.textRecognitionState {
                case .idle, .recognizing:
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在本机识别中…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .recognized:
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("识别出 \(model.recognizedCharacterCount) 个字符")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("重新识别") {
                                model.retryTextRecognition()
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }

                        ScrollView {
                            Text(model.recognizedText)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(10)
                        }
                        .background(
                            Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        }

                        Button("复制文字", systemImage: "doc.on.doc") {
                            model.copyRecognizedText()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.crossToolAccent)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                case .empty:
                    recognitionPlaceholder(
                        systemImage: "text.magnifyingglass",
                        title: "没有识别到文字",
                        detail: "可以确认截图里有清晰文字后再试一次"
                    )

                case .failed(let message):
                    recognitionPlaceholder(
                        systemImage: "exclamationmark.triangle",
                        title: "文字识别失败",
                        detail: message
                    )
                }
            }

            if let message = model.textCopyMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(
                        message.hasPrefix("复制文字失败") ? Color.red : Color.crossToolAccent
                    )
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func recognitionPlaceholder(
        systemImage: String,
        title: String,
        detail: String
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重新识别") {
                model.retryTextRecognition()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editorToolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    ForEach(ScreenshotEditTool.allCases, id: \.self) { tool in
                        toolButton(tool)
                    }
                }

                Spacer(minLength: 10)

                HStack(spacing: 4) {
                    Button {
                        model.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.canUndo || model.activeTextEntry != nil)
                    .help("撤销（⌘Z）")

                    Button {
                        model.redo()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo || model.activeTextEntry != nil)
                    .help("重做（⇧⌘Z）")

                    Button(role: .destructive) {
                        model.clearAnnotations()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(!model.hasAnnotations && model.activeTextEntry == nil)
                    .help("清空全部标注")
                }
                .buttonStyle(.bordered)
            }

            Divider()

            HStack(spacing: 14) {
                if model.selectedTool != .mosaic {
                    HStack(spacing: 6) {
                        ForEach(Self.palette, id: \.self) { color in
                            paletteButton(color)
                        }
                        ColorPicker(
                            "自定义颜色",
                            selection: selectedColorBinding,
                            supportsOpacity: false
                        )
                        .labelsHidden()
                        .frame(width: 28)
                        .help("自定义颜色")
                    }

                    Divider()
                        .frame(height: 24)
                }

                sizeControls
                Spacer(minLength: 8)

                if model.selectedTool == .sequence {
                    Text("单击图片自动生成序号，说明文字可选")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                } else if model.selectedTool == .text {
                    Text("单击图片后输入文字")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 104)
    }

    @ViewBuilder
    private var sizeControls: some View {
        if model.selectedTool == .mosaic {
            HStack(spacing: 8) {
                Text("笔刷")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $model.mosaicBrushDiameter, in: 16...120, step: 2)
                    .frame(width: 86)
                Text("\(Int(model.mosaicBrushDiameter))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)

                Text("颗粒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: mosaicPixelSizeBinding, in: 6...42, step: 2)
                    .frame(width: 70)
            }
        } else if model.selectedTool == .text || model.selectedTool == .sequence {
            HStack(spacing: 8) {
                Text("字号")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $model.textFontSize, in: 18...160, step: 1)
                    .frame(width: 110)
                Text("\(Int(model.textFontSize)) px")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)
            }
        } else {
            HStack(spacing: 8) {
                Text("粗细")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $model.lineWidth, in: 2...32, step: 1)
                    .frame(width: 94)
                Text("\(Int(model.lineWidth)) px")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let message = model.statusMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(Color.crossToolAccent)
                } else {
                    Text(footerHint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("原图尺寸 \(model.pixelWidth) × \(model.pixelHeight)，导出时保持原始分辨率")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button("关闭") {
                model.requestClose?()
            }
            .keyboardShortcut(.cancelAction)

            Button("复制图片", systemImage: "doc.on.doc") {
                model.copyToPasteboard()
            }
            .help("复制图片（⌘C；选中 OCR 文字时复制所选文字）")

            Button("另存为…", systemImage: "square.and.arrow.down") {
                model.saveAsPNG()
            }
            .keyboardShortcut("s", modifiers: .command)

            Button("加入课堂共享", systemImage: "person.2.fill") {
                model.addToShare()
            }
            .buttonStyle(.borderedProminent)
            .tint(.crossToolAccent)
        }
        .padding(.horizontal, 16)
        .frame(height: 72)
    }

    private var footerHint: String {
        switch model.selectedTool {
        case .text:
            "单击图片输入文字；按 Esc 取消本次输入"
        case .sequence:
            "单击图片添加序号并输入说明；按 Esc 取消本次输入"
        default:
            "拖动鼠标进行标注；按 S 可贴到屏幕"
        }
    }

    private func toolButton(_ tool: ScreenshotEditTool) -> some View {
        Button {
            model.selectTool(tool)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: tool.systemImage)
                    .font(.system(size: 16, weight: .medium))
                Text(tool.title)
                    .font(.caption2)
            }
            .foregroundStyle(model.selectedTool == tool ? Color.white : Color.primary)
            .frame(width: 50, height: 40)
            .background(
                model.selectedTool == tool
                    ? Color.crossToolAccent
                    : Color.primary.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(tool.helpText)
        .accessibilityLabel(tool.title)
        .accessibilityValue(model.selectedTool == tool ? "已选择" : "未选择")
    }

    private func paletteButton(_ color: ScreenshotRGBAColor) -> some View {
        Button {
            model.selectedColor = color
        } label: {
            Circle()
                .fill(color.swiftUIColor)
                .frame(width: 19, height: 19)
                .overlay {
                    Circle()
                        .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                }
                .padding(3)
                .overlay {
                    if model.selectedColor == color {
                        Circle()
                            .stroke(Color.crossToolAccent, lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .help("选择颜色")
    }

    private var selectedColorBinding: Binding<Color> {
        Binding(
            get: { model.selectedColor.swiftUIColor },
            set: { color in
                guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return }
                model.selectedColor = ScreenshotRGBAColor(
                    red: converted.redComponent,
                    green: converted.greenComponent,
                    blue: converted.blueComponent,
                    alpha: 1
                )
            }
        )
    }

    private var mosaicPixelSizeBinding: Binding<Double> {
        Binding(
            get: { model.mosaicPixelSize },
            set: { model.chooseMosaicPixelSize($0) }
        )
    }

    private static let palette: [ScreenshotRGBAColor] = [
        .red, .orange, .yellow, .green, .blue, .purple, .black, .white
    ]
}

private struct ScreenshotEditorCanvas: View {
    @ObservedObject var model: ScreenshotEditorViewModel

    private static let canvasCoordinateSpaceName = "ScreenshotEditorCanvas"

    var body: some View {
        GeometryReader { proxy in
            let imageRect = fittedImageRect(in: proxy.size)

            ZStack {
                Color(nsColor: .underPageBackgroundColor)

                Image(decorative: model.previewImage, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 4)

                ScreenshotDraftOverlay(
                    operation: model.draftOperation,
                    mosaicImage: model.mosaicPreviewImage,
                    imageRect: imageRect,
                    pixelWidth: model.pixelWidth,
                    pixelHeight: model.pixelHeight
                )

                Rectangle()
                    // A fully transparent SwiftUI shape can be omitted from
                    // macOS hit testing after the surrounding Canvas redraws.
                    // Keep an imperceptible alpha so this remains a real event
                    // surface for every drawing tool.
                    .fill(Color.white.opacity(0.001))
                    .contentShape(Rectangle())
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)
                    .highPriorityGesture(drawingGesture(imageRect: imageRect))
                    .accessibilityHidden(true)

                if let entry = model.activeTextEntry {
                    ScreenshotTextEntryEditor(model: model, entryID: entry.id)
                        .frame(width: entry.kind == .sequence ? 390 : 300)
                        .position(
                            textEditorPosition(
                                for: entry,
                                imageRect: imageRect
                            )
                        )
                        .id(entry.id)
                }

                Rectangle()
                    .stroke(Color.primary.opacity(0.16), lineWidth: 1)
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(name: Self.canvasCoordinateSpaceName)
            .clipped()
        }
    }

    private func fittedImageRect(in size: CGSize) -> CGRect {
        let availableWidth = max(1, size.width - 48)
        let availableHeight = max(1, size.height - 48)
        let scale = min(
            availableWidth / CGFloat(model.pixelWidth),
            availableHeight / CGFloat(model.pixelHeight)
        )
        let width = CGFloat(model.pixelWidth) * scale
        let height = CGFloat(model.pixelHeight) * scale
        return CGRect(
            x: (size.width - width) / 2,
            y: (size.height - height) / 2,
            width: width,
            height: height
        )
    }

    private func drawingGesture(imageRect: CGRect) -> some Gesture {
        DragGesture(
            minimumDistance: 0,
            coordinateSpace: .named(Self.canvasCoordinateSpaceName)
        )
            .onChanged { value in
                let router = ScreenshotEditorCanvasInteractionRouter(
                    coordinateMapper: coordinateMapper(for: imageRect)
                )
                perform(router.actions(
                    for: .changed(
                        startLocation: displayPoint(value.startLocation),
                        location: displayPoint(value.location),
                        hasDraftOperation: model.draftOperation != nil
                    ),
                    selectedTool: model.selectedTool
                ))
            }
            .onEnded { value in
                let router = ScreenshotEditorCanvasInteractionRouter(
                    coordinateMapper: coordinateMapper(for: imageRect)
                )
                perform(router.actions(
                    for: .ended(
                        startLocation: displayPoint(value.startLocation),
                        location: displayPoint(value.location)
                    ),
                    selectedTool: model.selectedTool
                ))
            }
    }

    private func displayPoint(_ point: CGPoint) -> ScreenshotEditDisplayPoint {
        ScreenshotEditDisplayPoint(x: Double(point.x), y: Double(point.y))
    }

    private func perform(
        _ actions: [ScreenshotEditorCanvasInteractionRouter.Action]
    ) {
        for action in actions {
            switch action {
            case .beginInteraction(let point):
                model.beginInteraction(at: point)
            case .updateInteraction(let point):
                model.updateInteraction(to: point)
            case .endInteraction(let point):
                model.endInteraction(at: point)
            case .beginTextEditing(let point):
                model.beginTextEditing(at: point)
            }
        }
    }

    private func coordinateMapper(for imageRect: CGRect) -> ScreenshotEditCoordinateMapper {
        ScreenshotEditCoordinateMapper(
            displayOriginX: Double(imageRect.minX),
            displayOriginY: Double(imageRect.minY),
            displayWidth: Double(imageRect.width),
            displayHeight: Double(imageRect.height),
            imagePixelWidth: model.pixelWidth,
            imagePixelHeight: model.pixelHeight
        )
    }

    private func textEditorPosition(
        for entry: ScreenshotTextEditingDraft,
        imageRect: CGRect
    ) -> CGPoint {
        let mapper = coordinateMapper(for: imageRect)
        let mapped = mapper.displayPoint(from: entry.origin)
        let editorWidth: CGFloat = entry.kind == .sequence ? 390 : 300
        let editorHeight: CGFloat = 48
        let markerHeight: CGFloat
        if entry.kind == .sequence,
           case .sequence(let annotation) = entry.operation {
            markerHeight = CGFloat(
                mapper.displayLength(fromImagePixels: annotation.badgeDiameter)
            )
        } else {
            markerHeight = CGFloat(
                mapper.displayLength(fromImagePixels: entry.fontSize)
            )
        }

        let minimumX = imageRect.minX + editorWidth / 2 + 4
        let maximumX = imageRect.maxX - editorWidth / 2 - 4
        let x = minimumX <= maximumX
            ? min(max(CGFloat(mapped.x) + editorWidth / 2, minimumX), maximumX)
            : imageRect.midX

        let below = CGFloat(mapped.y) + markerHeight + 8 + editorHeight / 2
        let above = CGFloat(mapped.y) - 8 - editorHeight / 2
        let y: CGFloat
        if below + editorHeight / 2 <= imageRect.maxY - 4 {
            y = below
        } else {
            y = max(imageRect.minY + editorHeight / 2 + 4, above)
        }
        return CGPoint(x: x, y: y)
    }
}

private struct ScreenshotTextEntryEditor: View {
    private enum Field: Hashable {
        case number
        case text
    }

    @ObservedObject var model: ScreenshotEditorViewModel
    let entryID: UUID
    @FocusState private var focusedField: Field?

    var body: some View {
        if let entry = model.activeTextEntry, entry.id == entryID {
            HStack(spacing: 7) {
                if entry.kind == .sequence {
                    TextField("1", text: numberBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .multilineTextAlignment(.center)
                        .frame(width: 76)
                        .focused($focusedField, equals: .number)
                        .onSubmit { focusedField = .text }
                        .accessibilityLabel("序号")
                        .accessibilityHint("可输入 1 到 999999，完成后下一项会自动加一")
                }

                TextField(
                    entry.kind == .sequence ? "输入说明（可选）" : "输入文字",
                    text: textBinding
                )
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .text)
                .onSubmit {
                    model.commitTextEditing()
                    focusedField = nil
                }
                .accessibilityLabel(
                    entry.kind == .sequence ? "说明文字" : "标注文字"
                )

                Button {
                    model.commitTextEditing()
                    focusedField = nil
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.crossToolAccent)
                .help("完成文字标注（Return）")
                .accessibilityLabel("完成文字标注")

                Button {
                    model.cancelTextEditing()
                    focusedField = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("取消本次文字标注（Esc）")
                .accessibilityLabel("取消本次文字标注")
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.crossToolAccent.opacity(0.75), lineWidth: 1.5)
            }
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            .onExitCommand {
                model.cancelTextEditing()
                focusedField = nil
            }
            .task(id: entryID) {
                await Task.yield()
                guard model.activeTextEntry?.id == entryID else { return }
                focusedField = .text
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(
                entry.kind == .sequence
                    ? "编辑序号 \(entry.resolvedNumber) 和说明文字"
                    : "编辑文字标注"
            )
        }
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { model.activeTextEntry?.text ?? "" },
            set: { model.updateActiveText($0) }
        )
    }

    private var numberBinding: Binding<String> {
        Binding(
            get: { model.activeTextEntry?.numberText ?? "" },
            set: { model.updateActiveSequenceNumber($0) }
        )
    }
}

private struct ScreenshotDraftOverlay: View {
    let operation: ScreenshotEditOperation?
    let mosaicImage: CGImage?
    let imageRect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int

    var body: some View {
        Canvas { context, _ in
            guard let operation else { return }
            switch operation {
            case .freehand(let stroke):
                drawFreehand(stroke, context: &context)
            case .mosaic(let stroke):
                drawMosaic(stroke, context: &context)
            case .rectangle(let annotation):
                drawRectangle(annotation, context: &context)
            case .arrow(let annotation):
                drawArrow(annotation, context: &context)
            case .text(let annotation):
                drawText(annotation, context: &context)
            case .sequence(let annotation):
                drawSequence(annotation, context: &context)
            }
        }
        .allowsHitTesting(false)
    }

    private func drawFreehand(_ stroke: ScreenshotFreehandStroke, context: inout GraphicsContext) {
        guard let first = stroke.points.first else { return }
        let width = displayLength(stroke.lineWidth)
        if stroke.points.count == 1 {
            let center = displayPoint(first)
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - width / 2, y: center.y - width / 2, width: width, height: width)),
                with: .color(stroke.color.swiftUIColor)
            )
            return
        }

        var path = Path()
        path.move(to: displayPoint(first))
        for point in stroke.points.dropFirst() {
            path.addLine(to: displayPoint(point))
        }
        context.stroke(
            path,
            with: .color(stroke.color.swiftUIColor),
            style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawMosaic(_ stroke: ScreenshotMosaicStroke, context: inout GraphicsContext) {
        guard let first = stroke.points.first, let mosaicImage else { return }
        let diameter = displayLength(stroke.brushDiameter)
        let mask: Path
        if stroke.points.count == 1 {
            let center = displayPoint(first)
            mask = Path(ellipseIn: CGRect(
                x: center.x - diameter / 2,
                y: center.y - diameter / 2,
                width: diameter,
                height: diameter
            ))
        } else {
            var path = Path()
            path.move(to: displayPoint(first))
            for point in stroke.points.dropFirst() {
                path.addLine(to: displayPoint(point))
            }
            mask = path.strokedPath(StrokeStyle(
                lineWidth: diameter,
                lineCap: .round,
                lineJoin: .round
            ))
        }

        context.clip(to: mask)
        context.draw(Image(decorative: mosaicImage, scale: 1), in: imageRect)
    }

    private func drawRectangle(
        _ annotation: ScreenshotRectangleAnnotation,
        context: inout GraphicsContext
    ) {
        let start = displayPoint(annotation.start)
        let end = displayPoint(annotation.end)
        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        context.stroke(
            Path(rect),
            with: .color(annotation.color.swiftUIColor),
            style: StrokeStyle(
                lineWidth: displayLength(annotation.lineWidth),
                lineCap: .round,
                lineJoin: .round
            )
        )
    }

    private func drawArrow(_ annotation: ScreenshotArrowAnnotation, context: inout GraphicsContext) {
        let start = displayPoint(annotation.start)
        let end = displayPoint(annotation.end)
        let width = displayLength(annotation.lineWidth)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        let sourceLength = hypot(
            annotation.end.x - annotation.start.x,
            annotation.end.y - annotation.start.y
        )
        // Match the model and full-resolution renderer: a one-source-pixel
        // arrow remains visible even when the preview is scaled below 1×.
        guard sourceLength >= 1, length > 0 else { return }
        let sourceHeadLength = min(
            max(annotation.lineWidth * 4.5, 12),
            max(12, sourceLength * 0.36)
        )
        let headLength = displayLength(sourceHeadLength)
        let angle = atan2(dy, dx)
        let spread = CGFloat.pi / 6

        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        path.move(to: CGPoint(
            x: end.x - headLength * cos(angle - spread),
            y: end.y - headLength * sin(angle - spread)
        ))
        path.addLine(to: end)
        path.addLine(to: CGPoint(
            x: end.x - headLength * cos(angle + spread),
            y: end.y - headLength * sin(angle + spread)
        ))
        context.stroke(
            path,
            with: .color(annotation.color.swiftUIColor),
            style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawText(
        _ annotation: ScreenshotTextAnnotation,
        context: inout GraphicsContext
    ) {
        guard !annotation.text.isEmpty else { return }
        context.draw(
            Text(annotation.text)
                .font(.system(
                    size: displayLength(annotation.fontSize),
                    weight: .medium
                ))
                .foregroundStyle(annotation.color.swiftUIColor),
            at: displayPoint(annotation.origin),
            anchor: .topLeading
        )
    }

    private func drawSequence(
        _ annotation: ScreenshotSequenceAnnotation,
        context: inout GraphicsContext
    ) {
        let origin = displayPoint(annotation.origin)
        let diameter = displayLength(annotation.badgeDiameter)
        let badgeRect = CGRect(
            x: origin.x,
            y: origin.y,
            width: diameter,
            height: diameter
        )
        context.fill(
            Path(ellipseIn: badgeRect),
            with: .color(annotation.color.swiftUIColor)
        )
        context.draw(
            Text(String(annotation.number))
                .font(.system(
                    size: displayLength(annotation.badgeFontSize),
                    weight: .bold,
                    design: .rounded
                ))
                .monospacedDigit()
                .foregroundStyle(annotation.color.contrastingTextColor.swiftUIColor),
            at: CGPoint(x: badgeRect.midX, y: badgeRect.midY),
            anchor: .center
        )

        guard !annotation.text.isEmpty else { return }
        context.draw(
            Text(annotation.text)
                .font(.system(
                    size: displayLength(annotation.fontSize),
                    weight: .medium
                ))
                .foregroundStyle(annotation.color.swiftUIColor),
            at: CGPoint(
                x: badgeRect.maxX + displayLength(annotation.textGap),
                y: badgeRect.midY
            ),
            anchor: .leading
        )
    }

    private func displayPoint(_ point: ScreenshotEditPoint) -> CGPoint {
        let point = coordinateMapper.displayPoint(from: point)
        return CGPoint(x: point.x, y: point.y)
    }

    private func displayLength(_ pixels: Double) -> CGFloat {
        CGFloat(coordinateMapper.displayLength(fromImagePixels: pixels))
    }

    private var coordinateMapper: ScreenshotEditCoordinateMapper {
        ScreenshotEditCoordinateMapper(
            displayOriginX: Double(imageRect.minX),
            displayOriginY: Double(imageRect.minY),
            displayWidth: Double(imageRect.width),
            displayHeight: Double(imageRect.height),
            imagePixelWidth: pixelWidth,
            imagePixelHeight: pixelHeight
        )
    }
}

private extension ScreenshotEditTool {
    var title: String {
        switch self {
        case .pen: "画笔"
        case .mosaic: "马赛克"
        case .rectangle: "矩形"
        case .arrow: "箭头"
        case .text: "文字"
        case .sequence: "序号"
        }
    }

    var systemImage: String {
        switch self {
        case .pen: "pencil.tip"
        case .mosaic: "square.grid.3x3.fill"
        case .rectangle: "rectangle"
        case .arrow: "arrow.up.right"
        case .text: "character.cursor.ibeam"
        case .sequence: "1.circle"
        }
    }

    var helpText: String {
        switch self {
        case .text:
            "文字：单击图片后输入"
        case .sequence:
            "序号：单击自动递增，可修改数字并输入说明"
        default:
            title
        }
    }
}

private extension ScreenshotRGBAColor {
    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    var contrastingTextColor: ScreenshotRGBAColor {
        let luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722
        return luminance > 0.58 ? .black : .white
    }
}
