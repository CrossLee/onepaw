import Carbon
import CrossToolCore
import Foundation

extension ScreenshotMode {
    var shortcutLabel: String {
        shortcutLabel(using: Self.defaultGlobalShortcuts)
    }

    func shortcutLabel(using shortcuts: [ScreenshotMode: GlobalShortcut]) -> String {
        shortcuts[self]?.displayLabel ?? "未设置"
    }

    static let defaultGlobalShortcuts: [ScreenshotMode: GlobalShortcut] = Dictionary(
        uniqueKeysWithValues: GlobalShortcutCommand.defaultGlobalShortcuts.compactMap {
            command, shortcut in command.screenshotMode.map { ($0, shortcut) }
        }
    )

    /// All screenshot tools can be assigned by the user. Only the established
    /// first three reserve global keys on a fresh install.
    static let globalShortcutModes: [ScreenshotMode] = [
        .region,
        .window,
        .screen,
        .delayedScreen,
        .framedScreen,
        .multiWindow,
        .scrolling,
    ]

    /// The three established bindings must always remain present. New guided
    /// modes are optional and deliberately have no default so a fresh install
    /// or upgrade never loses the working set because an extra key is occupied.
    static let requiredGlobalShortcutModes: Set<ScreenshotMode> = [
        .region,
        .window,
        .screen,
    ]

    var defaultGlobalShortcut: GlobalShortcut? {
        Self.defaultGlobalShortcuts[self]
    }

    var hotKeyID: UInt32? {
        shortcutCommand.registrationID
    }

    fileprivate init?(hotKeyID: UInt32) {
        guard let command = GlobalShortcutCommand(registrationID: hotKeyID),
              let mode = command.screenshotMode else { return nil }
        self = mode
    }

    var shortcutCommand: GlobalShortcutCommand {
        switch self {
        case .region: return .screenshotRegion
        case .window: return .screenshotWindow
        case .screen: return .screenshotScreen
        case .delayedScreen: return .screenshotDelayed
        case .framedScreen: return .screenshotFramed
        case .multiWindow: return .screenshotMultiWindow
        case .scrolling: return .screenshotScrolling
        }
    }
}

extension GlobalShortcutCommand {
    static let defaultGlobalShortcuts: [Self: GlobalShortcut] = [
        .screenshotRegion: GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_1),
            modifiers: [.control, .shift]
        ),
        .screenshotWindow: GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_2),
            modifiers: [.control, .shift]
        ),
        .screenshotScreen: GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_3),
            modifiers: [.control, .shift]
        ),
    ]

    static let requiredGlobalShortcutCommands: Set<Self> = [
        .screenshotRegion,
        .screenshotWindow,
        .screenshotScreen,
    ]

    var screenshotMode: ScreenshotMode? {
        switch self {
        case .screenshotRegion: return .region
        case .screenshotWindow: return .window
        case .screenshotScreen: return .screen
        case .screenshotDelayed: return .delayedScreen
        case .screenshotFramed: return .framedScreen
        case .screenshotMultiWindow: return .multiWindow
        case .screenshotScrolling: return .scrolling
        case .recordCurrentDisplay, .recordRegion, .recordWindow, .stopRecording,
             .pickColor, .translateText, .formatClipboardJSON, .showMainWindow:
            return nil
        }
    }

    var title: String {
        if let screenshotMode { return screenshotMode.title }
        switch self {
        case .recordCurrentDisplay: return "录制当前屏幕"
        case .recordRegion: return "录制选定区域"
        case .recordWindow: return "录制窗口"
        case .stopRecording: return "停止录屏"
        case .pickColor: return "提取颜色"
        case .translateText: return "选中文字并翻译"
        case .formatClipboardJSON: return "格式化剪贴板 JSON"
        case .showMainWindow: return "显示一爪主界面"
        case .screenshotRegion, .screenshotWindow, .screenshotScreen,
             .screenshotDelayed, .screenshotFramed, .screenshotMultiWindow,
             .screenshotScrolling:
            preconditionFailure("Screenshot commands are handled above")
        }
    }

    var systemImage: String {
        if let screenshotMode { return screenshotMode.systemImage }
        switch self {
        case .recordCurrentDisplay: return "display"
        case .recordRegion: return "viewfinder"
        case .recordWindow: return "macwindow"
        case .stopRecording: return "stop.circle.fill"
        case .pickColor: return "eyedropper"
        case .translateText: return "bubble.left.and.bubble.right"
        case .formatClipboardJSON: return "curlybraces.square"
        case .showMainWindow: return "macwindow"
        case .screenshotRegion, .screenshotWindow, .screenshotScreen,
             .screenshotDelayed, .screenshotFramed, .screenshotMultiWindow,
             .screenshotScrolling:
            preconditionFailure("Screenshot commands are handled above")
        }
    }

    func shortcutLabel(using shortcuts: [Self: GlobalShortcut]) -> String {
        shortcuts[self]?.displayLabel ?? "未设置"
    }
}

@MainActor
final class GlobalHotKeyManager {
    enum ValidationIssue: Equatable {
        case missingBinding(GlobalShortcutCommand)
        case invalidBinding(GlobalShortcutCommand, [GlobalShortcutValidationIssue])
        case duplicateBinding([GlobalShortcutCommand])

        var affectedCommands: [GlobalShortcutCommand] {
            switch self {
            case .missingBinding(let command), .invalidBinding(let command, _):
                return [command]
            case .duplicateBinding(let commands):
                return commands
            }
        }

        /// Compatibility for callers that still render screenshot-only rows.
        var affectedModes: [ScreenshotMode] {
            affectedCommands.compactMap(\.screenshotMode)
        }

        var message: String {
            switch self {
            case .missingBinding(let command):
                return "\(command.title)缺少快捷键"
            case .invalidBinding(let command, let issues):
                let details = issues.compactMap(\.errorDescription).joined(separator: "；")
                return "\(command.title)：\(details)"
            case .duplicateBinding(let commands):
                return "\(commands.map(\.title).joined(separator: "、"))不能使用同一个快捷键"
            }
        }
    }

    struct RegistrationResult {
        let command: GlobalShortcutCommand
        let shortcut: GlobalShortcut
        let status: OSStatus

        var succeeded: Bool { status == noErr }

        /// Compatibility for screenshot-only diagnostics.
        var mode: ScreenshotMode? { command.screenshotMode }
    }

    struct StartResult {
        let shortcuts: [GlobalShortcutCommand: GlobalShortcut]
        let validationIssues: [ValidationIssue]
        let handlerStatus: OSStatus
        let registrations: [RegistrationResult]

        var succeeded: Bool {
            let attemptedCommandCount = GlobalShortcutCommand.allCases
                .filter { shortcuts[$0] != nil }
                .count
            return validationIssues.isEmpty
                && handlerStatus == noErr
                && registrations.count == attemptedCommandCount
                && registrations.allSatisfy(\.succeeded)
        }

        var failedCommands: [GlobalShortcutCommand] {
            if !validationIssues.isEmpty {
                let affected = Set(validationIssues.flatMap(\.affectedCommands))
                return GlobalShortcutCommand.allCases.filter { affected.contains($0) }
            }
            guard handlerStatus == noErr else {
                return GlobalShortcutCommand.allCases.filter { shortcuts[$0] != nil }
            }
            let resultsByCommand = Dictionary(
                uniqueKeysWithValues: registrations.map { ($0.command, $0) }
            )
            return GlobalShortcutCommand.allCases.filter {
                shortcuts[$0] != nil && resultsByCommand[$0]?.succeeded != true
            }
        }

        /// Compatibility for callers that still render screenshot-only rows.
        var failedModes: [ScreenshotMode] {
            failedCommands.compactMap(\.screenshotMode)
        }
    }

    struct ReconfigurationResult {
        let previousShortcuts: [GlobalShortcutCommand: GlobalShortcut]?
        let attemptedShortcuts: [GlobalShortcutCommand: GlobalShortcut]
        let startResult: StartResult
        let rollbackStartResult: StartResult?

        var succeeded: Bool { startResult.succeeded }
        var rollbackSucceeded: Bool { rollbackStartResult?.succeeded == true }
    }

    typealias Action = @MainActor @Sendable (GlobalShortcutCommand) -> Void
    typealias LegacyScreenshotAction = @MainActor @Sendable (ScreenshotMode) -> Void

    private static let signature: OSType = 0x4352_5354 // "CRST"
    private let action: Action
    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var pressedCommands: Set<GlobalShortcutCommand> = []
    private(set) var configuredShortcuts: [GlobalShortcutCommand: GlobalShortcut]?

    init(action: @escaping Action) {
        self.action = action
    }

    /// Temporary source compatibility while screenshot-only callers migrate
    /// to the unified command callback.
    convenience init(action: @escaping LegacyScreenshotAction) {
        self.init { command in
            guard let mode = command.screenshotMode else { return }
            action(mode)
        }
    }

    @discardableResult
    func start(
        shortcuts: [GlobalShortcutCommand: GlobalShortcut] = GlobalShortcutCommand.defaultGlobalShortcuts
    ) -> StartResult {
        stop()

        let validationIssues = Self.validate(shortcuts: shortcuts)
        guard validationIssues.isEmpty else {
            return StartResult(
                shortcuts: shortcuts,
                validationIssues: validationIssues,
                handlerStatus: OSStatus(paramErr),
                registrations: []
            )
        }

        let eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]
        var installedHandler: EventHandlerRef?
        let handlerStatus = eventTypes.withUnsafeBufferPointer { eventTypesBuffer in
            InstallEventHandler(
                GetApplicationEventTarget(),
                Self.handleHotKeyEvent,
                eventTypesBuffer.count,
                eventTypesBuffer.baseAddress,
                Unmanaged.passUnretained(self).toOpaque(),
                &installedHandler
            )
        }
        guard handlerStatus == noErr, let installedHandler else {
            return StartResult(
                shortcuts: shortcuts,
                validationIssues: [],
                handlerStatus: handlerStatus,
                registrations: []
            )
        }
        eventHandlerRef = installedHandler

        var registrations: [RegistrationResult] = []
        registrations.reserveCapacity(GlobalShortcutCommand.allCases.count)

        for command in GlobalShortcutCommand.allCases {
            guard let shortcut = shortcuts[command] else { continue }
            var hotKeyRef: EventHotKeyRef?
            let identifier = EventHotKeyID(
                signature: Self.signature,
                id: command.registrationID
            )
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                Self.carbonModifiers(shortcut.modifiers),
                identifier,
                GetApplicationEventTarget(),
                UInt32(kEventHotKeyExclusive),
                &hotKeyRef
            )
            if status == noErr, let hotKeyRef {
                hotKeyRefs.append(hotKeyRef)
            }
            registrations.append(
                RegistrationResult(command: command, shortcut: shortcut, status: status)
            )
        }

        let result = StartResult(
            shortcuts: shortcuts,
            validationIssues: [],
            handlerStatus: handlerStatus,
            registrations: registrations
        )
        guard result.succeeded else {
            // Never leave a partially active shortcut set behind. In
            // particular, a collision on one command must not silently switch
            // the other commands to the candidate configuration.
            stop()
            return result
        }

        configuredShortcuts = shortcuts
        return result
    }

    /// Temporary source compatibility for the previous screenshot-only map.
    @discardableResult
    func start(shortcuts: [ScreenshotMode: GlobalShortcut]) -> StartResult {
        start(shortcuts: Self.commandShortcuts(from: shortcuts))
    }

    @discardableResult
    func reconfigure(
        shortcuts: [GlobalShortcutCommand: GlobalShortcut]
    ) -> ReconfigurationResult {
        let previousShortcuts = configuredShortcuts
        let startResult = start(shortcuts: shortcuts)
        let rollbackStartResult: StartResult?
        if !startResult.succeeded, let previousShortcuts {
            rollbackStartResult = start(shortcuts: previousShortcuts)
        } else {
            rollbackStartResult = nil
        }
        return ReconfigurationResult(
            previousShortcuts: previousShortcuts,
            attemptedShortcuts: shortcuts,
            startResult: startResult,
            rollbackStartResult: rollbackStartResult
        )
    }

    /// Temporary source compatibility for the previous screenshot-only map.
    @discardableResult
    func reconfigure(
        shortcuts: [ScreenshotMode: GlobalShortcut]
    ) -> ReconfigurationResult {
        reconfigure(shortcuts: Self.commandShortcuts(from: shortcuts))
    }

    func stop() {
        for hotKeyRef in hotKeyRefs {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        pressedCommands.removeAll()
        configuredShortcuts = nil
    }

    private static let handleHotKeyEvent: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else {
            return OSStatus(eventNotHandledErr)
        }

        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard status == noErr,
              identifier.signature == GlobalHotKeyManager.signature,
              let command = GlobalShortcutCommand(registrationID: identifier.id) else {
            return OSStatus(eventNotHandledErr)
        }

        let eventKind = GetEventKind(event)
        guard eventKind == UInt32(kEventHotKeyPressed)
                || eventKind == UInt32(kEventHotKeyReleased) else {
            return OSStatus(eventNotHandledErr)
        }

        let manager = Unmanaged<GlobalHotKeyManager>
            .fromOpaque(userData)
            .takeUnretainedValue()

        // Events installed on GetApplicationEventTarget are normally handled
        // by the main event loop. Keep press/release ordering synchronous there
        // so key-repeat presses cannot overtake their release. The fallback is
        // defensive for a manually posted event arriving from another thread.
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                manager.handle(command: command, eventKind: eventKind)
            }
        } else {
            Task { @MainActor in
                manager.handle(command: command, eventKind: eventKind)
            }
        }
        return noErr
    }

    private func handle(command: GlobalShortcutCommand, eventKind: UInt32) {
        if eventKind == UInt32(kEventHotKeyReleased) {
            pressedCommands.remove(command)
            return
        }

        guard pressedCommands.insert(command).inserted else {
            return
        }
        action(command)
    }

    static func validate(
        shortcuts: [GlobalShortcutCommand: GlobalShortcut]
    ) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        for command in GlobalShortcutCommand.allCases {
            guard let shortcut = shortcuts[command] else {
                if GlobalShortcutCommand.requiredGlobalShortcutCommands.contains(command) {
                    issues.append(.missingBinding(command))
                }
                continue
            }
            let shortcutIssues = shortcut.validationIssues
            if !shortcutIssues.isEmpty {
                issues.append(.invalidBinding(command, shortcutIssues))
            }
        }

        var visited = Set<GlobalShortcutCommand>()
        for command in GlobalShortcutCommand.allCases where !visited.contains(command) {
            guard let shortcut = shortcuts[command] else { continue }
            let duplicates = GlobalShortcutCommand.allCases.filter {
                guard let candidate = shortcuts[$0] else { return false }
                return shortcut.conflicts(with: candidate)
            }
            visited.formUnion(duplicates)
            if duplicates.count > 1 {
                issues.append(.duplicateBinding(duplicates))
            }
        }

        return issues
    }

    /// Temporary source compatibility for the previous screenshot-only map.
    static func validate(
        shortcuts: [ScreenshotMode: GlobalShortcut]
    ) -> [ValidationIssue] {
        validate(shortcuts: commandShortcuts(from: shortcuts))
    }

    private static func commandShortcuts(
        from shortcuts: [ScreenshotMode: GlobalShortcut]
    ) -> [GlobalShortcutCommand: GlobalShortcut] {
        Dictionary(uniqueKeysWithValues: shortcuts.map { mode, shortcut in
            (mode.shortcutCommand, shortcut)
        })
    }

    private static func carbonModifiers(_ modifiers: GlobalShortcutModifiers) -> UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }
}
