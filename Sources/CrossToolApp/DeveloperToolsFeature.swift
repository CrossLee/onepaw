import AppKit
import CrossToolCore
import Foundation
import SwiftUI

enum DeveloperToolKind: String, CaseIterable, Identifiable, Sendable {
    case jsonFormatter
    case base64Encoder
    case uuidGenerator

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jsonFormatter: return "JSON 格式化"
        case .base64Encoder: return "Base64 编码"
        case .uuidGenerator: return "UUID 生成"
        }
    }
}

struct DeveloperToolsFeedback: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case information
        case success
        case error

        var systemImage: String {
            switch self {
            case .information: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .error: return "exclamationmark.triangle.fill"
            }
        }

        var color: Color {
            switch self {
            case .information: return .crossToolAccent
            case .success: return .green
            case .error: return .red
            }
        }
    }

    let kind: Kind
    let message: String
}

@MainActor
final class DeveloperToolsFeatureModel: ObservableObject {
    static let maximumInteractiveInputBytes = JSONTextFormatter.maximumInputBytes

    @Published var selectedTool: DeveloperToolKind = .jsonFormatter {
        didSet {
            guard selectedTool != oldValue else { return }
            if oldValue == .jsonFormatter {
                cancelJSONFormatting()
            }
            feedback = nil
        }
    }
    @Published private(set) var jsonInput = ""
    @Published private(set) var jsonOutput = ""
    @Published private(set) var isFormattingJSON = false
    @Published private(set) var base64Input = ""
    @Published private(set) var base64Output = ""
    @Published var uuidCount = 1 {
        didSet {
            guard uuidCount != oldValue else { return }
            uuidOutput = ""
            feedback = nil
        }
    }
    @Published var uuidFormat: UUIDTextFormat = .lowercase {
        didSet {
            guard uuidFormat != oldValue else { return }
            uuidOutput = ""
            feedback = nil
        }
    }
    @Published private(set) var uuidOutput = ""
    @Published private(set) var feedback: DeveloperToolsFeedback?

    private let pasteboard: NSPasteboard
    private var jsonFormattingTask: Task<Void, Never>?
    private var jsonFormattingGeneration: UInt64 = 0

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    deinit {
        jsonFormattingTask?.cancel()
    }

    func updateJSONInput(_ input: String) {
        guard input != jsonInput else { return }
        jsonInput = input
        jsonOutput = ""
        cancelJSONFormatting()
        feedback = nil
    }

    func pasteJSON() {
        guard let text = readablePasteboardText() else { return }
        updateJSONInput(text)
    }

    func clearJSON() {
        jsonInput = ""
        jsonOutput = ""
        cancelJSONFormatting()
        feedback = nil
    }

    func formatJSON() {
        let source = jsonInput
        jsonFormattingGeneration &+= 1
        let generation = jsonFormattingGeneration
        jsonFormattingTask?.cancel()
        isFormattingJSON = true
        jsonOutput = ""
        feedback = nil

        jsonFormattingTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let outcome = await Task.detached(priority: .userInitiated) {
                do {
                    return JSONFormattingOutcome.success(
                        try JSONTextFormatter.format(source)
                    )
                } catch {
                    return JSONFormattingOutcome.failure(error.localizedDescription)
                }
            }.value

            guard !Task.isCancelled,
                  let self,
                  generation == self.jsonFormattingGeneration else {
                return
            }

            self.isFormattingJSON = false
            self.jsonFormattingTask = nil
            switch outcome {
            case .success(let output):
                self.jsonOutput = output
                self.feedback = DeveloperToolsFeedback(
                    kind: .success,
                    message: "JSON 已完成严格校验和格式化。"
                )
            case .failure(let message):
                self.feedback = DeveloperToolsFeedback(kind: .error, message: message)
            }
        }
    }

    func copyJSONResult() {
        copy(jsonOutput, successMessage: "格式化结果已复制。")
    }

    func updateBase64Input(_ input: String) {
        guard input != base64Input else { return }
        base64Input = input
        base64Output = ""
        feedback = nil
    }

    func pasteBase64() {
        guard let text = readablePasteboardText() else { return }
        updateBase64Input(text)
    }

    func clearBase64() {
        base64Input = ""
        base64Output = ""
        feedback = nil
    }

    func encodeBase64() {
        guard !base64Input.isEmpty else {
            feedback = DeveloperToolsFeedback(
                kind: .information,
                message: "请先输入要编码的文字。"
            )
            return
        }
        guard base64Input.utf8.count <= Self.maximumInteractiveInputBytes else {
            feedback = DeveloperToolsFeedback(
                kind: .error,
                message: Self.inputTooLargeMessage
            )
            return
        }

        base64Output = Base64TextEncoder.encode(base64Input)
        feedback = DeveloperToolsFeedback(
            kind: .success,
            message: "已按原始 UTF-8 内容完成 Base64 编码。"
        )
    }

    func copyBase64Result() {
        copy(base64Output, successMessage: "Base64 编码结果已复制。")
    }

    func generateUUIDs() {
        do {
            uuidOutput = try UUIDTextGenerator.generate(
                count: uuidCount,
                format: uuidFormat
            )
            feedback = DeveloperToolsFeedback(
                kind: .success,
                message: uuidCount == 1 ? "UUID 已生成。" : "已生成 \(uuidCount) 个 UUID。"
            )
        } catch {
            uuidOutput = ""
            feedback = DeveloperToolsFeedback(
                kind: .error,
                message: error.localizedDescription
            )
        }
    }

    func copyUUIDResult() {
        copy(uuidOutput, successMessage: "UUID 已复制。")
    }

    func dismissFeedback() {
        feedback = nil
    }

    private func cancelJSONFormatting() {
        jsonFormattingGeneration &+= 1
        jsonFormattingTask?.cancel()
        jsonFormattingTask = nil
        isFormattingJSON = false
    }

    private func readablePasteboardText() -> String? {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            feedback = DeveloperToolsFeedback(
                kind: .information,
                message: "剪贴板里没有可用的文字。"
            )
            return nil
        }
        return text
    }

    private func copy(_ text: String, successMessage: String) {
        guard !text.isEmpty else { return }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            feedback = DeveloperToolsFeedback(
                kind: .error,
                message: "没有成功写入剪贴板，请重试。"
            )
            return
        }
        feedback = DeveloperToolsFeedback(kind: .success, message: successMessage)
    }

    private static var inputTooLargeMessage: String {
        let mebibytes = maximumInteractiveInputBytes / 1_048_576
        return "内容超过 \(mebibytes) MB，请缩小后再处理。"
    }
}

private enum JSONFormattingOutcome: Sendable {
    case success(String)
    case failure(String)
}

struct DeveloperToolsPage: View {
    @ObservedObject var model: DeveloperToolsFeatureModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "开发工具",
                    subtitle: "整理常用文本格式，无需打开网页"
                )

                privacyBanner
                toolPicker
                toolContent
            }
            .padding(30)
        }
    }

    private var privacyBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.crossToolAccent)
            VStack(alignment: .leading, spacing: 3) {
                Text("内容只在这台 Mac 上处理")
                    .font(.subheadline.weight(.semibold))
                Text("不会上传，也不会自动加入课堂共享区；点击复制后，会按你的设置进入复制历史。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.crossToolAccent.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var toolPicker: some View {
        Picker("工具", selection: $model.selectedTool) {
            ForEach(DeveloperToolKind.allCases) { tool in
                Text(tool.title).tag(tool)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .accessibilityLabel("选择开发工具")
    }

    @ViewBuilder
    private var toolContent: some View {
        switch model.selectedTool {
        case .jsonFormatter:
            jsonFormatter
        case .base64Encoder:
            base64Encoder
        case .uuidGenerator:
            uuidGenerator
        }
    }

    private var jsonFormatter: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                editorCard(
                    title: "原始 JSON",
                    text: Binding(
                        get: { model.jsonInput },
                        set: { model.updateJSONInput($0) }
                    ),
                    placeholder: "输入或粘贴 JSON 内容",
                    isEditable: true,
                    footer: "严格校验 · 最多 1 MB"
                ) {
                    Button("粘贴", systemImage: "doc.on.clipboard") {
                        model.pasteJSON()
                    }
                    Button("清空", systemImage: "xmark") {
                        model.clearJSON()
                    }
                    .disabled(model.jsonInput.isEmpty)
                }

                editorCard(
                    title: "格式化结果",
                    text: .constant(model.jsonOutput),
                    placeholder: model.isFormattingJSON ? "正在格式化…" : "结果会显示在这里",
                    isEditable: false,
                    footer: "保留键顺序、数字与转义"
                ) {
                    Button("复制结果", systemImage: "doc.on.doc") {
                        model.copyJSONResult()
                    }
                    .disabled(model.jsonOutput.isEmpty)
                }
            }

            feedbackIfPresent

            primaryButton(
                title: model.isFormattingJSON ? "正在格式化…" : "格式化",
                systemImage: "curlybraces",
                isWorking: model.isFormattingJSON,
                isDisabled: model.jsonInput.isEmpty || model.isFormattingJSON
            ) {
                model.formatJSON()
            }
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private var base64Encoder: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                editorCard(
                    title: "原始文字",
                    text: Binding(
                        get: { model.base64Input },
                        set: { model.updateBase64Input($0) }
                    ),
                    placeholder: "输入或粘贴要编码的文字",
                    isEditable: true,
                    footer: "按原始 UTF-8 字节编码"
                ) {
                    Button("粘贴", systemImage: "doc.on.clipboard") {
                        model.pasteBase64()
                    }
                    Button("清空", systemImage: "xmark") {
                        model.clearBase64()
                    }
                    .disabled(model.base64Input.isEmpty)
                }

                editorCard(
                    title: "编码结果",
                    text: .constant(model.base64Output),
                    placeholder: "Base64 结果会显示在这里",
                    isEditable: false,
                    footer: "标准 Base64 · 不自动换行"
                ) {
                    Button("复制结果", systemImage: "doc.on.doc") {
                        model.copyBase64Result()
                    }
                    .disabled(model.base64Output.isEmpty)
                }
            }

            Label("Base64 是编码，不是加密，不能代替密码保护。", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            feedbackIfPresent

            primaryButton(
                title: "编码",
                systemImage: "arrow.right.square",
                isWorking: false,
                isDisabled: model.base64Input.isEmpty
            ) {
                model.encodeBase64()
            }
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private var uuidGenerator: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 20) {
                Stepper("生成数量：\(model.uuidCount)", value: $model.uuidCount, in: 1...100)
                    .frame(maxWidth: 210, alignment: .leading)

                Picker("格式", selection: $model.uuidFormat) {
                    ForEach(UUIDTextFormat.allCases, id: \.self) { format in
                        Text(uuidFormatTitle(format)).tag(format)
                    }
                }
                .frame(maxWidth: 260)

                Spacer(minLength: 0)

                Button("生成", systemImage: "arrow.clockwise") {
                    model.generateUUIDs()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(16)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.crossToolBorder, lineWidth: 1)
            }

            feedbackIfPresent

            editorCard(
                title: "生成结果",
                text: .constant(model.uuidOutput),
                placeholder: "点击“生成”创建 UUID",
                isEditable: false,
                footer: model.uuidOutput.isEmpty ? "每行显示一个 UUID" : "共 \(model.uuidCount) 个"
            ) {
                Button("复制结果", systemImage: "doc.on.doc") {
                    model.copyUUIDResult()
                }
                .disabled(model.uuidOutput.isEmpty)
            }

            Label("UUID 适合用作唯一标识，不应当作密码或访问令牌。", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var feedbackIfPresent: some View {
        if let feedback = model.feedback {
            feedbackBanner(feedback)
        }
    }

    private func editorCard<TrailingActions: View>(
        title: String,
        text: Binding<String>,
        placeholder: String,
        isEditable: Bool,
        footer: String,
        @ViewBuilder trailingActions: () -> TrailingActions
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.headline)
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    trailingActions()
                }
                .buttonStyle(.borderless)
            }

            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 6)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }

                TextEditor(text: text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(1)
                    .disabled(!isEditable)
                    .accessibilityLabel(title)
            }
            .frame(minHeight: 250)
            .padding(8)
            .background(Color.secondary.opacity(isEditable ? 0.035 : 0.055))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.crossToolBorder, lineWidth: 1)
            }

            HStack {
                Text(footer)
                Spacer()
                Text("\(text.wrappedValue.count) 字符")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.crossToolBorder, lineWidth: 1)
        }
    }

    private func primaryButton(
        title: String,
        systemImage: String,
        isWorking: Bool,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .frame(minWidth: 112)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isDisabled)
    }

    private func feedbackBanner(_ feedback: DeveloperToolsFeedback) -> some View {
        HStack(spacing: 10) {
            Image(systemName: feedback.kind.systemImage)
                .foregroundStyle(feedback.kind.color)
            Text(feedback.message)
                .font(.subheadline)
            Spacer(minLength: 8)
            Button {
                model.dismissFeedback()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(feedback.kind.color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("处理提示")
        .accessibilityValue(feedback.message)
    }

    private func uuidFormatTitle(_ format: UUIDTextFormat) -> String {
        switch format {
        case .lowercase: return "小写"
        case .uppercase: return "大写"
        }
    }
}
