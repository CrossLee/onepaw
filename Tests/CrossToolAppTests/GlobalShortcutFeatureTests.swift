import CrossToolCore
import Testing
@testable import CrossToolApp

@MainActor
@Suite("Global shortcut feature metadata")
struct GlobalShortcutFeatureTests {
    @Test("Clipboard JSON and main-window shortcuts are optional and descriptive")
    func optionalCommandMetadata() {
        #expect(GlobalShortcutCommand.defaultGlobalShortcuts[.formatClipboardJSON] == nil)
        #expect(GlobalShortcutCommand.defaultGlobalShortcuts[.showMainWindow] == nil)
        #expect(!GlobalShortcutCommand.requiredGlobalShortcutCommands.contains(.formatClipboardJSON))
        #expect(!GlobalShortcutCommand.requiredGlobalShortcutCommands.contains(.showMainWindow))
        #expect(GlobalShortcutCommand.formatClipboardJSON.title == "格式化剪贴板 JSON")
        #expect(GlobalShortcutCommand.showMainWindow.title == "显示一爪主界面")
        #expect(GlobalShortcutCommand.formatClipboardJSON.systemImage == "curlybraces.square")
        #expect(GlobalShortcutCommand.showMainWindow.systemImage == "macwindow")
        #expect(GlobalShortcutCommand.formatClipboardJSON.screenshotMode == nil)
        #expect(GlobalShortcutCommand.showMainWindow.screenshotMode == nil)
        #expect(GlobalShortcutCommand.formatClipboardJSON.recordingSource == nil)
        #expect(GlobalShortcutCommand.showMainWindow.recordingSource == nil)
    }

    @Test("New commands participate in duplicate validation")
    func duplicateValidation() {
        let duplicate = GlobalShortcut(
            keyCode: 37,
            modifiers: [.control, .option]
        )
        var shortcuts = GlobalShortcutCommand.defaultGlobalShortcuts
        shortcuts[.formatClipboardJSON] = duplicate
        shortcuts[.showMainWindow] = duplicate

        let issues = GlobalHotKeyManager.validate(shortcuts: shortcuts)

        #expect(issues.contains { issue in
            guard case .duplicateBinding(let commands) = issue else { return false }
            return commands == [.formatClipboardJSON, .showMainWindow]
        })
    }
}
