import Foundation

/// Every OnePaw tool action that can be invoked by a global shortcut.
///
/// The explicit raw values are persistence identifiers. They must stay stable
/// across releases even if a command's user-facing title changes.
public enum GlobalShortcutCommand: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    case screenshotRegion = "screenshot.region"
    case screenshotWindow = "screenshot.window"
    case screenshotScreen = "screenshot.screen"
    case screenshotDelayed = "screenshot.delayed"
    case screenshotFramed = "screenshot.framed"
    case screenshotMultiWindow = "screenshot.multiWindow"
    case screenshotScrolling = "screenshot.scrolling"
    case recordCurrentDisplay = "recording.currentDisplay"
    case recordRegion = "recording.region"
    case recordWindow = "recording.window"
    case stopRecording = "recording.stop"
    case pickColor = "color.pick"
    case translateText = "translation.text"
    case formatClipboardJSON = "developer.jsonFormatClipboard"
    case showMainWindow = "application.showMainWindow"

    public var id: String { rawValue }

    /// Stable Carbon identifiers. These values are part of the event routing
    /// contract and must not be renumbered when commands are reordered.
    public var registrationID: UInt32 {
        switch self {
        case .screenshotRegion: return 1
        case .screenshotWindow: return 2
        case .screenshotScreen: return 3
        case .screenshotDelayed: return 4
        case .screenshotFramed: return 5
        case .screenshotMultiWindow: return 6
        case .screenshotScrolling: return 7
        case .recordCurrentDisplay: return 101
        case .recordRegion: return 102
        case .recordWindow: return 103
        case .stopRecording: return 104
        case .pickColor: return 201
        case .translateText: return 301
        case .formatClipboardJSON: return 401
        case .showMainWindow: return 501
        }
    }

    public init?(registrationID: UInt32) {
        guard let command = Self.allCases.first(where: { $0.registrationID == registrationID }) else {
            return nil
        }
        self = command
    }

    /// Converts a command-keyed configuration into the string-keyed object
    /// persisted by OnePaw. Unknown future keys can therefore be ignored by an
    /// older build without making the whole payload undecodable.
    public static func persistedBindings(
        from shortcuts: [Self: GlobalShortcut]
    ) -> [String: GlobalShortcut] {
        Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
    }

    /// Decodes the known portion of a string-keyed persisted configuration.
    public static func shortcuts(
        fromPersistedBindings bindings: [String: GlobalShortcut]
    ) -> [Self: GlobalShortcut] {
        Dictionary(uniqueKeysWithValues: bindings.compactMap { rawCommand, shortcut in
            Self(rawValue: rawCommand).map { ($0, shortcut) }
        })
    }
}

public struct GlobalShortcutSafetyMigrationResult: Equatable, Sendable {
    public let shortcuts: [GlobalShortcutCommand: GlobalShortcut]
    public let resetCommands: [GlobalShortcutCommand]
    public let clearedCommands: [GlobalShortcutCommand]

    public var didChange: Bool {
        !resetCommands.isEmpty || !clearedCommands.isEmpty
    }
}

public extension GlobalShortcutCommand {
    /// Removes legacy Command-only bindings that would globally override basic
    /// application menu shortcuts. Required commands receive the first free
    /// safe fallback; optional commands are left unbound. Every unaffected
    /// binding is preserved exactly.
    static func migratingUnsafeCommandOnlyBindings(
        _ shortcuts: [Self: GlobalShortcut],
        requiredCommands: Set<Self>,
        fallbackCandidates: [GlobalShortcut]
    ) -> GlobalShortcutSafetyMigrationResult? {
        let unsafeCommands = allCases.filter { command in
            shortcuts[command]?.validationIssues.contains(
                .commandOnlyShortcutWouldOverrideApplications
            ) == true
        }

        var sanitized = shortcuts
        var resetCommands: [Self] = []
        var clearedCommands: [Self] = []
        for command in unsafeCommands {
            sanitized.removeValue(forKey: command)
            if requiredCommands.contains(command) {
                guard let fallback = fallbackCandidates.first(where: { candidate in
                    candidate.isValid
                        && sanitized.values.allSatisfy {
                            !$0.conflicts(with: candidate)
                        }
                }) else {
                    return nil
                }
                sanitized[command] = fallback
                resetCommands.append(command)
            } else {
                clearedCommands.append(command)
            }
        }

        guard requiredCommands.allSatisfy({ sanitized[$0] != nil }),
              sanitized.values.allSatisfy(\.isValid) else {
            return nil
        }

        let configured = allCases.compactMap { command in
            sanitized[command].map { (command, $0) }
        }
        for index in configured.indices {
            for otherIndex in configured.indices where otherIndex > index {
                if configured[index].1.conflicts(with: configured[otherIndex].1) {
                    return nil
                }
            }
        }

        return GlobalShortcutSafetyMigrationResult(
            shortcuts: sanitized,
            resetCommands: resetCommands,
            clearedCommands: clearedCommands
        )
    }
}

/// Modifier keys used by a Carbon global shortcut.
///
/// The raw value is deliberately independent of Carbon's flag constants so
/// shortcut settings remain portable and stable when encoded in UserDefaults.
public struct GlobalShortcutModifiers: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = GlobalShortcutModifiers(rawValue: 1 << 0)
    public static let control = GlobalShortcutModifiers(rawValue: 1 << 1)
    public static let option = GlobalShortcutModifiers(rawValue: 1 << 2)
    public static let shift = GlobalShortcutModifiers(rawValue: 1 << 3)

    public static let supported: GlobalShortcutModifiers = [
        .command,
        .control,
        .option,
        .shift,
    ]

    /// Command and Control are the strong modifiers accepted for global use.
    public var containsStrongModifier: Bool {
        contains(.command) || contains(.control)
    }

    public var count: Int {
        rawValue.nonzeroBitCount
    }

    public var containsUnsupportedModifier: Bool {
        !subtracting(.supported).isEmpty
    }

    /// Standard macOS menu order using explicit names so users do not have to
    /// translate the macOS Control symbol (`⌃`) before recording a shortcut.
    public var displayLabel: String {
        var components: [String] = []
        if contains(.control) { components.append("Ctrl") }
        if contains(.option) { components.append("Option") }
        if contains(.shift) { components.append("Shift") }
        if contains(.command) { components.append("Command") }
        return components.joined(separator: "+")
    }
}

public enum GlobalShortcutValidationIssue: Equatable, Hashable, Sendable, LocalizedError {
    case requiresCommandOrControlModifier
    case commandOnlyShortcutWouldOverrideApplications
    case unsupportedModifier
    case unsupportedTriggerKey
    case missingKeyDisplay

    public var errorDescription: String? {
        switch self {
        case .requiresCommandOrControlModifier:
            return "快捷键必须包含 Ctrl，或使用 Command 与 Option/Shift 的组合"
        case .commandOnlyShortcutWouldOverrideApplications:
            return "仅使用 Command 会抢占其他应用的菜单快捷键，请改用 Ctrl 加主键，或再加 Option/Shift"
        case .unsupportedModifier:
            return "快捷键包含不支持的修饰键"
        case .unsupportedTriggerKey:
            return "不能使用 Esc、修饰键、Fn 或媒体键作为快捷键主键"
        case .missingKeyDisplay:
            return "快捷键缺少可显示的主键"
        }
    }
}

/// A physical macOS key plus the modifiers used to register it globally.
///
/// `keyCode` is the hardware-independent macOS virtual key code consumed by
/// Carbon. `keyDisplay` is persisted alongside it so the UI can show an exact,
/// user-friendly label even for non-US keyboard layouts.
public struct GlobalShortcut: Equatable, Hashable, Sendable, Codable {
    public let keyCode: UInt32
    public let keyDisplay: String
    public let modifiers: GlobalShortcutModifiers

    public init(
        keyCode: UInt32,
        keyDisplay: String,
        modifiers: GlobalShortcutModifiers
    ) {
        self.keyCode = keyCode
        self.keyDisplay = keyDisplay
        self.modifiers = modifiers
    }

    /// Convenience initializer for programmatic defaults and common keys.
    public init(keyCode: UInt32, modifiers: GlobalShortcutModifiers) {
        self.init(
            keyCode: keyCode,
            keyDisplay: Self.defaultKeyDisplay(for: keyCode),
            modifiers: modifiers
        )
    }

    public var displayLabel: String {
        let modifierLabel = modifiers.displayLabel
        guard !modifierLabel.isEmpty else { return keyDisplay }
        return modifierLabel + "+" + keyDisplay
    }

    public var validationIssues: [GlobalShortcutValidationIssue] {
        var issues: [GlobalShortcutValidationIssue] = []
        if !modifiers.containsStrongModifier {
            issues.append(.requiresCommandOrControlModifier)
        }
        if modifiers == .command {
            issues.append(.commandOnlyShortcutWouldOverrideApplications)
        }
        if modifiers.containsUnsupportedModifier {
            issues.append(.unsupportedModifier)
        }
        if !Self.isSupportedTriggerKey(keyCode) {
            issues.append(.unsupportedTriggerKey)
        }
        if keyDisplay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.missingKeyDisplay)
        }
        return issues
    }

    public var isValid: Bool {
        validationIssues.isEmpty
    }

    /// Registration conflicts are defined by key code and modifiers. The
    /// display label is descriptive and must not affect duplicate detection.
    public func conflicts(with other: GlobalShortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    public static func isSupportedTriggerKey(_ keyCode: UInt32) -> Bool {
        // Apple's hardware-independent virtual key constants occupy 0x00...
        // 0x7E. Values outside that range cannot represent a Carbon key.
        guard keyCode <= 0x7E else { return false }
        switch keyCode {
        case 53: // Escape
            return false
        case 54 ... 63: // Command/Shift/Caps Lock/Option/Control/Fn variants
            return false
        case 72 ... 74: // Volume up/down/mute media keys
            return false
        default:
            return true
        }
    }

    /// Labels for common ANSI, navigation and function keys. A recorder can
    /// supply a layout-aware `keyDisplay`; this fallback keeps decoded/default
    /// shortcuts readable without AppKit.
    public static func defaultKeyDisplay(for keyCode: UInt32) -> String {
        keyDisplays[keyCode] ?? "按键\(keyCode)"
    }

    private static let keyDisplays: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 48: "⇥", 49: "空格", 50: "`",
        51: "⌫", 36: "↩", 64: "F17", 65: "小键盘.", 67: "小键盘*",
        69: "小键盘+", 71: "清除", 75: "小键盘/",
        76: "↩", 78: "小键盘-", 81: "小键盘=", 82: "小键盘0",
        83: "小键盘1", 84: "小键盘2", 85: "小键盘3", 86: "小键盘4",
        87: "小键盘5", 88: "小键盘6", 89: "小键盘7", 91: "小键盘8",
        92: "小键盘9", 93: "¥", 94: "_", 95: "小键盘,", 96: "F5",
        97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 102: "英数",
        103: "F11", 104: "かな", 105: "F13", 106: "F16", 107: "F14",
        109: "F10", 111: "F12", 113: "F15", 114: "Help", 115: "↖",
        116: "⇞", 117: "⌦", 118: "F4", 119: "↘", 120: "F2",
        121: "⇟", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
        79: "F18", 80: "F19", 90: "F20",
    ]
}
