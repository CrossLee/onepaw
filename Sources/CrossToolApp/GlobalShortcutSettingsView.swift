import AppKit
import CrossToolCore
import SwiftUI

struct GlobalShortcutSettingsSection: View {
    @EnvironmentObject private var model: AppModel

    @State private var stagedShortcuts: [GlobalShortcutCommand: GlobalShortcut] = [:]
    @State private var recordingCommand: GlobalShortcutCommand?
    @State private var validationErrors: [GlobalShortcutCommand: String] = [:]
    @State private var recordingErrors: [GlobalShortcutCommand: String] = [:]
    @State private var applyError: String?
    @State private var successMessage: String?
    @State private var hasLoadedInitialValues = false

    private let screenshotCommands: [GlobalShortcutCommand] = [
        .screenshotRegion,
        .screenshotWindow,
        .screenshotScreen,
        .screenshotDelayed,
        .screenshotFramed,
        .screenshotMultiWindow,
        .screenshotScrolling,
    ]
    private let recordingCommands: [GlobalShortcutCommand] = [
        .recordCurrentDisplay,
        .recordRegion,
        .recordWindow,
    ]
    private let colorCommands: [GlobalShortcutCommand] = [
        .pickColor,
    ]
    private let translationCommands: [GlobalShortcutCommand] = [
        .translateText,
    ]
    private let developerToolCommands: [GlobalShortcutCommand] = [
        .formatClipboardJSON,
    ]
    private let applicationCommands: [GlobalShortcutCommand] = [
        .showMainWindow,
    ]

    var body: some View {
        Group {
            shortcutSection(title: "截图", commands: screenshotCommands)
            shortcutSection(title: "录屏", commands: recordingCommands)
            shortcutSection(title: "提取颜色", commands: colorCommands)
            shortcutSection(title: "翻译", commands: translationCommands)
            shortcutSection(title: "开发工具", commands: developerToolCommands)
            shortcutSection(title: "应用", commands: applicationCommands)

            Section("全局快捷键设置") {
                settingsStatus
                settingsActions
            }
        }
        .onAppear {
            guard !hasLoadedInitialValues else { return }
            stagedShortcuts = model.globalShortcuts
            validationErrors = validate(stagedShortcuts)
            hasLoadedInitialValues = true
        }
        .onDisappear {
            endRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            cancelRecording()
        }
    }

    @ViewBuilder
    private func shortcutSection(
        title: String,
        commands: [GlobalShortcutCommand]
    ) -> some View {
        Section(title) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(commands) { command in
                    shortcutRow(for: command)

                    if command != commands.last {
                        Divider()
                            .padding(.leading, 42)
                    }
                }
            }

            if commands.contains(.translateText) {
                Label(
                    "快捷翻译优先通过辅助功能读取选中文字；少数 App 不提供选中文字时，会短暂执行复制并尽力恢复原剪贴板。密码框和安全输入不会读取。",
                    systemImage: "accessibility"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if commands.contains(.formatClipboardJSON) {
                Label(
                    "先复制 JSON 文字，再按快捷键；一爪会读取当前剪贴板，打开开发工具并自动格式化。此操作不会改写剪贴板，也不需要辅助功能权限。",
                    systemImage: "doc.on.clipboard"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func shortcutRow(for command: GlobalShortcutCommand) -> some View {
        let isRecording = recordingCommand == command
        // A previous invalid attempt should not keep the row red while the
        // user is recording a replacement. Recording errors take over until
        // a valid combination is received or recording is cancelled.
        let error = recordingErrors[command]
            ?? (isRecording ? nil : validationErrors[command])
        let stagedLabel = stagedShortcuts[command]?.displayLabel ?? "未设置"
        let hasRowChange = stagedShortcuts[command] != model.globalShortcuts[command]

        HStack(alignment: .top, spacing: 12) {
            Image(systemName: command.systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.crossToolAccent)
                .frame(width: 30, height: 30)
                .background(Color.crossToolAccent.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(command.title)
                    .font(.body.weight(.medium))
                Text("当前：\(model.shortcutLabel(for: command))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 20)

            VStack(alignment: .trailing, spacing: 5) {
                ShortcutRecorderField(
                    accessibilityName: command.title,
                    label: stagedLabel,
                    isRecording: isRecording,
                    showsError: error != nil,
                    errorMessage: error,
                    hasPendingChange: hasRowChange,
                    onBeginRecording: { beginRecording(command) },
                    onKeyEvent: { event in handle(event, for: command) }
                )

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 300, alignment: .trailing)
                        .accessibilityLabel("\(command.title)快捷键错误：\(error)")
                }
            }
        }
        .padding(.vertical, 11)
    }

    private var settingsStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("点击右侧按键框后，按住 Ctrl 不松开，再按一个主键，例如 Ctrl+A。也支持 Ctrl+Shift+A、Ctrl+Option+A 等组合；按 Esc 可取消。为避免抢占其他 App 的保存、关闭等操作，不允许仅使用 Command 加主键。区域、窗口和全屏截图必须保留快捷键；其余功能可在录制时按 Delete 清除。")
                .font(.callout)
                .foregroundStyle(.secondary)

            if recordingCommand != nil {
                Label("正在录制，现有全局快捷键已暂时停用", systemImage: "keyboard")
                    .font(.callout)
                    .foregroundStyle(Color.crossToolAccent)
            } else if let applyError {
                Label(applyError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if let successMessage {
                Label(successMessage, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else if let warning = model.globalShortcutWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if !hasPendingChanges {
                Label("当前快捷键已启用", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
        }
    }

    private var settingsActions: some View {
        HStack(spacing: 10) {
            Button("恢复默认", systemImage: "arrow.counterclockwise") {
                restoreDefaults()
            }
            .disabled(
                recordingCommand != nil
                    || stagedShortcuts == model.defaultGlobalShortcuts
            )

            Spacer()

            if hasPendingChanges {
                Text("更改尚未应用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("应用更改") {
                applyChanges()
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                recordingCommand != nil
                    || !hasPendingChanges
                    || !validationErrors.isEmpty
                    || !recordingErrors.isEmpty
            )
        }
    }

    private var hasPendingChanges: Bool {
        stagedShortcuts != model.globalShortcuts
    }

    private func beginRecording(_ command: GlobalShortcutCommand) {
        if recordingCommand != nil {
            model.setGlobalShortcutRecordingActive(false)
        }
        recordingErrors.removeAll()
        validationErrors.removeValue(forKey: command)
        applyError = nil
        successMessage = nil
        recordingCommand = command
        model.setGlobalShortcutRecordingActive(true)
    }

    private func handle(_ event: ShortcutKeyEvent, for command: GlobalShortcutCommand) {
        guard recordingCommand == command else { return }

        if event.keyCode == 53 { // Escape
            cancelRecording()
            return
        }

        let modifiers = GlobalShortcutModifiers(event.modifierFlags)
        if (event.keyCode == 51 || event.keyCode == 117),
           modifiers.isEmpty { // Unmodified Delete / Forward Delete clears optional rows.
            if GlobalShortcutCommand.requiredGlobalShortcutCommands.contains(command) {
                recordingErrors[command] = "这个常用截图入口必须保留快捷键"
            } else {
                stagedShortcuts.removeValue(forKey: command)
                recordingErrors[command] = nil
                validationErrors = validate(stagedShortcuts)
                applyError = nil
                successMessage = nil
                endRecording()
            }
            return
        }
        if event.hasUnsupportedModifiers {
            recordingErrors[command] = "组合中包含 Fn、Caps Lock 或其他不支持的修饰键"
            return
        }

        let shortcut = GlobalShortcut(
            keyCode: UInt32(event.keyCode),
            keyDisplay: keyDisplay(for: event),
            modifiers: modifiers
        )

        if let issue = shortcut.validationIssues.first {
            recordingErrors[command] = recordingMessage(for: issue)
            return
        }

        stagedShortcuts[command] = shortcut
        recordingErrors[command] = nil
        validationErrors = validate(stagedShortcuts)
        applyError = nil
        successMessage = nil
        endRecording()
    }

    private func cancelRecording() {
        guard recordingCommand != nil else { return }
        recordingErrors.removeAll()
        validationErrors = validate(stagedShortcuts)
        endRecording()
    }

    private func endRecording() {
        if recordingCommand != nil {
            recordingCommand = nil
            model.setGlobalShortcutRecordingActive(false)
        }
    }

    private func restoreDefaults() {
        cancelRecording()
        stagedShortcuts = model.defaultGlobalShortcuts
        recordingErrors.removeAll()
        validationErrors = validate(stagedShortcuts)
        applyError = nil
        successMessage = nil
    }

    private func applyChanges() {
        endRecording()
        validationErrors = validate(stagedShortcuts)
        guard validationErrors.isEmpty else { return }

        do {
            try model.applyGlobalShortcuts(stagedShortcuts)
            applyError = nil
            successMessage = "新的全局快捷键已启用"
        } catch {
            successMessage = nil
            applyError = error.localizedDescription
        }
    }

    private func validate(
        _ shortcuts: [GlobalShortcutCommand: GlobalShortcut]
    ) -> [GlobalShortcutCommand: String] {
        var errors: [GlobalShortcutCommand: String] = [:]

        for command in GlobalShortcutCommand.allCases {
            guard let shortcut = shortcuts[command] else {
                if GlobalShortcutCommand.requiredGlobalShortcutCommands.contains(command) {
                    errors[command] = "必须设置一个快捷键"
                }
                continue
            }
            for issue in shortcut.validationIssues {
                let message = validationMessage(for: issue)
                errors[command] = appendValidationMessage(message, to: errors[command])
            }
        }

        for (index, command) in GlobalShortcutCommand.allCases.enumerated() {
            guard let shortcut = shortcuts[command] else { continue }
            for otherCommand in GlobalShortcutCommand.allCases.dropFirst(index + 1) {
                guard let otherShortcut = shortcuts[otherCommand],
                      shortcut.conflicts(with: otherShortcut) else { continue }
                errors[command] = appendValidationMessage(
                    "与“\(otherCommand.title)”重复",
                    to: errors[command]
                )
                errors[otherCommand] = appendValidationMessage(
                    "与“\(command.title)”重复",
                    to: errors[otherCommand]
                )
            }
        }

        return errors
    }

    private func appendValidationMessage(_ message: String, to existing: String?) -> String {
        guard let existing else { return message }
        return "\(existing)；\(message)"
    }

    private func recordingMessage(for issue: GlobalShortcutValidationIssue) -> String {
        switch issue {
        case .requiresCommandOrControlModifier:
            return "未检测到 Ctrl。请按住 Ctrl 不松开，再按一个主键"
        default:
            return validationMessage(for: issue)
        }
    }

    private func validationMessage(for issue: GlobalShortcutValidationIssue) -> String {
        switch issue {
        case .requiresCommandOrControlModifier:
            return "快捷键需要包含 Ctrl；也可以使用 Command+Option/Shift 加主键"
        case .commandOnlyShortcutWouldOverrideApplications:
            return "仅用 Command 会抢占其他 App 的常用操作；请改用 Ctrl，或再加 Option/Shift"
        case .unsupportedModifier:
            return "组合中包含不支持的修饰键"
        case .unsupportedTriggerKey:
            return "不能使用 Esc、修饰键、Fn 或媒体键作为主键"
        case .missingKeyDisplay:
            return "无法识别这个主键，请换一个按键"
        }
    }

    private func keyDisplay(for event: ShortcutKeyEvent) -> String {
        // For printable keys, keep the active keyboard layout's character.
        // Navigation/function keys use the stable labels provided by Core.
        if event.keyCode <= 47,
           let characters = event.charactersWithoutModifiers,
           !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            return characters.uppercased()
        }
        return GlobalShortcut.defaultKeyDisplay(for: UInt32(event.keyCode))
    }
}

private struct ShortcutRecorderField: View {
    let accessibilityName: String
    let label: String
    let isRecording: Bool
    let showsError: Bool
    let errorMessage: String?
    let hasPendingChange: Bool
    let onBeginRecording: () -> Void
    let onKeyEvent: (ShortcutKeyEvent) -> Void

    var body: some View {
        Button(action: onBeginRecording) {
            HStack(spacing: 7) {
                Image(systemName: isRecording ? "keyboard.fill" : "keyboard")
                    .foregroundStyle(isRecording ? Color.crossToolAccent : Color.secondary)
                    .accessibilityHidden(true)

                Text(isRecording ? "请按快捷键…" : label)
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                if hasPendingChange && !isRecording {
                    Text("待应用")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.crossToolAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.crossToolAccent.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
            .frame(minWidth: 180, minHeight: 30)
            .padding(.horizontal, 10)
            .background(isRecording ? Color.crossToolAccent.opacity(0.09) : Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColor, lineWidth: isRecording ? 2 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            ShortcutKeyCaptureView(isRecording: isRecording, onKeyEvent: onKeyEvent)
        }
        .accessibilityLabel("\(accessibilityName)快捷键")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("按下后，按住 Control 不松开，再按一个主键，例如 Control A；也可继续加入 Shift、Option 或 Command")
    }

    private var accessibilityValue: String {
        if isRecording {
            if let errorMessage {
                return "正在录制。\(errorMessage)。按 Escape 取消"
            }
            return "正在录制，按 Escape 取消"
        }
        if let errorMessage {
            return "\(label)。错误：\(errorMessage)"
        }
        return label
    }

    private var borderColor: Color {
        if showsError { return .red.opacity(0.75) }
        if isRecording { return .crossToolAccent }
        return .crossToolBorder
    }
}

private struct ShortcutKeyEvent {
    let keyCode: UInt16
    let modifierFlags: NSEvent.ModifierFlags
    let charactersWithoutModifiers: String?
    let hasUnsupportedModifiers: Bool
}

private struct ShortcutKeyCaptureView: NSViewRepresentable {
    let isRecording: Bool
    let onKeyEvent: (ShortcutKeyEvent) -> Void

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        view.onKeyEvent = onKeyEvent
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureNSView, context: Context) {
        nsView.onKeyEvent = onKeyEvent
        nsView.isRecording = isRecording

        if isRecording {
            nsView.window?.makeFirstResponder(nsView)
        } else if nsView.window?.firstResponder === nsView {
            nsView.window?.makeFirstResponder(nil)
        }
    }
}

private final class ShortcutCaptureNSView: NSView {
    var isRecording = false
    var onKeyEvent: ((ShortcutKeyEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        submit(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }

        // AppKit normally routes Command combinations through menu key
        // equivalents before keyDown. Consume them here so combinations such
        // as Command-Shift-letter can still be recorded by this field.
        submit(event)
        return true
    }

    private func submit(_ event: NSEvent) {
        let deviceIndependentFlags = event.modifierFlags.intersection(
            .deviceIndependentFlagsMask
        )
        let supportedFlags: NSEvent.ModifierFlags = [
            .command,
            .control,
            .option,
            .shift,
            .numericPad,
        ]
        onKeyEvent?(
            ShortcutKeyEvent(
                keyCode: event.keyCode,
                modifierFlags: deviceIndependentFlags,
                charactersWithoutModifiers: event.characters(byApplyingModifiers: []),
                hasUnsupportedModifiers: !deviceIndependentFlags
                    .subtracting(supportedFlags)
                    .isEmpty
            )
        )
    }
}

private extension GlobalShortcutModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
    }
}
