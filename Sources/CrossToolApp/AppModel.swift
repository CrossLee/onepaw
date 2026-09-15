import AppKit
import CoreGraphics
import CrossToolCore
import Foundation
import OSLog
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    private static let logger = Logger(
        subsystem: "com.cross.crosstool",
        category: "GlobalShortcuts"
    )

    @Published private(set) var serverState: LocalHTTPServerState = .stopped
    @Published private(set) var sharedItems: [SharedItem] = []
    @Published private(set) var receivedItems: [SharedItem] = []
    @Published private(set) var publicItems: [SharedItem] = []
    @Published var notice: String?
    @Published var isCapturing = false
    @Published private(set) var hasScreenCapturePermission = CGPreflightScreenCaptureAccess()
    @Published private(set) var globalShortcutWarning: String?
    @Published private(set) var globalShortcuts = GlobalShortcutCommand.defaultGlobalShortcuts
    @Published var selectedDestination: SidebarDestination? = .home
    @Published private(set) var mainWindowOpenRequestID = 0
    @Published private(set) var mainWindowDismissRequestID = 0
    @Published private(set) var textTranslationLaunchRequest: TextTranslationLaunchRequest?

    @Published private(set) var sessionToken: String
    @Published private(set) var usesCustomShareAccessCode: Bool
    let colorSampler = ColorSamplerViewModel()
    let imageCompression = ImageCompressionFeatureModel()
    let screenRecording = ScreenRecordingFeatureModel()
    @Published private(set) var port: UInt16 = 5421

    private let store: SharedContentStore
    private let router: HTTPRouter
    private let server: LocalHTTPServer
    private let defaults: UserDefaults
    private let screenshotService: ScreenshotService
    private let screenshotPasteboardWriter = ScreenshotPasteboardWriter()
    private let screenshotsDirectory: URL
    private let screenshotDraftsDirectory: URL
    private var globalHotKeyManager: GlobalHotKeyManager?
    private var isGlobalShortcutRecordingActive = false
    private var screenCapturePermissionGate = ScreenCapturePermissionGate()
    private var screenshotEditorWindowController: ScreenshotEditorWindowController?
    private let pinnedScreenshotManager = PinnedScreenshotManager()
    private let selectedTextCaptureService = SelectedTextCaptureService()
    private var selectedTextTranslationTask: Task<Void, Never>?
    private var isPreparingColorSampling = false
    private var lastClaimedMainWindowOpenRequestID = 0

    init(defaults: UserDefaults = .standard) {
        let directories = Self.makeDirectories()
        let shortcutLoadResult = Self.loadGlobalShortcuts()
        let loadedAccessCode = ShareAccessCodePreferences.load(from: defaults)
        Self.removeStaleScreenshotDrafts(in: directories.drafts)
        let createdStore: SharedContentStore
        var storageConflict = false
        var fallbackRoot: URL?
        var storeInitializationWarning: String?
        do {
            createdStore = try SharedContentStore(inboxDirectory: directories.inbox)
        } catch SharedContentStoreError.storageInUse {
            storageConflict = true
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "onepaw-secondary-launch-\(UUID().uuidString)",
                    isDirectory: true
                )
            fallbackRoot = root
            createdStore = try! SharedContentStore(
                inboxDirectory: root.appendingPathComponent("Inbox", isDirectory: true)
            )
        } catch {
            let fallback = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "onepaw-fallback-\(UUID().uuidString)",
                    isDirectory: true
                )
                .appendingPathComponent("Inbox", isDirectory: true)
            createdStore = try! SharedContentStore(inboxDirectory: fallback)
            storeInitializationWarning = "共享记录目录暂时不可用：\(error.localizedDescription)"
        }

        let token = loadedAccessCode.value
        let web = Self.loadWebResources()
        let router = HTTPRouter(
            store: createdStore,
            sessionToken: token,
            indexHTML: web.index,
            assets: web.assets
        )

        self.store = createdStore
        self.router = router
        self.defaults = defaults
        self.sessionToken = token
        self.usesCustomShareAccessCode = loadedAccessCode.usesCustomValue
        self.server = LocalHTTPServer(router: router, port: 5421)
        self.screenshotService = ScreenshotService(outputDirectory: directories.drafts)
        self.screenshotsDirectory = directories.screenshots
        self.screenshotDraftsDirectory = directories.drafts
        self.globalShortcuts = shortcutLoadResult.shortcuts
        if storageConflict {
            if let fallbackRoot {
                try? FileManager.default.removeItem(at: fallbackRoot)
            }
            DispatchQueue.main.async {
                let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.cross.crosstool"
                let currentPID = ProcessInfo.processInfo.processIdentifier
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                    .first(where: { $0.processIdentifier != currentPID })?
                    .activate(options: [.activateAllWindows])
                NSApp.terminate(nil)
            }
            return
        }

        OnePawApplicationDelegate.recordingModel = screenRecording
        OnePawApplicationDelegate.mainWindowOpenRequestBroker.install { [weak self] in
            self?.presentMainWindow()
        }
        OnePawApplicationDelegate.imageOpenRequestBroker.install { [weak self] urls in
            self?.presentImageCompression(importing: urls)
        }

        createdStore.setChangeHandler { [weak self] in
            Task { @MainActor in
                self?.refreshItems(announcesNewIncoming: true)
            }
        }
        server.setStateHandler { [weak self] state in
            Task { @MainActor in
                self?.serverState = state
                if case .running(let actualPort) = state {
                    self?.port = actualPort
                }
            }
        }

        let hotKeyManager = GlobalHotKeyManager { [weak self] (command: GlobalShortcutCommand) in
            self?.performGlobalShortcut(command)
        }
        globalHotKeyManager = hotKeyManager
        let shortcutResult = hotKeyManager.start(shortcuts: globalShortcuts)
        if !shortcutResult.succeeded {
            globalShortcutWarning = Self.inactiveShortcutSetMessage(for: shortcutResult)
            let failed = shortcutResult.failedCommands
                .map { $0.shortcutLabel(using: globalShortcuts) }
                .joined(separator: "、")
            Self.logger.error("Global shortcut registration failed: \(failed, privacy: .public)")
        } else {
            if shortcutLoadResult.shouldPersist,
               let encoded = try? JSONEncoder().encode(
                   PersistedGlobalToolShortcuts(globalShortcuts)
               ) {
                UserDefaults.standard.set(
                    encoded,
                    forKey: Self.globalToolShortcutsDefaultsKey
                )
            }
            globalShortcutWarning = shortcutLoadResult.migrationNotice
            let labels = GlobalShortcutCommand.allCases
                .compactMap { command in
                    globalShortcuts[command].map { "\(command.title):\($0.displayLabel)" }
                }
                .joined(separator: "/")
            Self.logger.info("Registered global tool shortcuts: \(labels, privacy: .public)")
        }

        refreshItems(announcesNewIncoming: false)
        startServer()
        if let storeInitializationWarning {
            notice = storeInitializationWarning
        }
    }

    var isServerRunning: Bool {
        if case .running = serverState { return true }
        return false
    }

    var shareURL: String {
        let address = LocalNetworkAddress.bestIPv4Address() ?? "127.0.0.1"
        return ShareLinkBuilder.url(
            host: address,
            port: port,
            accessCode: sessionToken
        )?.absoluteString ?? "http://\(address):\(port)/"
    }

    var localPreviewURL: URL? {
        ShareLinkBuilder.url(
            host: "127.0.0.1",
            port: port,
            accessCode: sessionToken
        )
    }

    var shareAddress: String {
        let address = LocalNetworkAddress.bestIPv4Address() ?? "127.0.0.1"
        return "\(address):\(port)"
    }

    var defaultGlobalShortcuts: [GlobalShortcutCommand: GlobalShortcut] {
        GlobalShortcutCommand.defaultGlobalShortcuts
    }

    func shortcutLabel(for mode: ScreenshotMode) -> String {
        shortcutLabel(for: mode.shortcutCommand)
    }

    func shortcutLabel(for command: GlobalShortcutCommand) -> String {
        command.shortcutLabel(using: globalShortcuts)
    }

    func configuredShortcutLabel(for command: GlobalShortcutCommand) -> String? {
        globalShortcuts[command]?.displayLabel
    }

    func applyGlobalShortcuts(_ shortcuts: [GlobalShortcutCommand: GlobalShortcut]) throws {
        let validationIssues = GlobalHotKeyManager.validate(shortcuts: shortcuts)
        guard validationIssues.isEmpty else {
            throw GlobalShortcutSettingsError.invalid(
                validationIssues.map(\.message).joined(separator: "；")
            )
        }

        // Encode before touching the active registrations. This makes the
        // operation transactional even if the persisted representation fails.
        let encoded = try JSONEncoder().encode(PersistedGlobalToolShortcuts(shortcuts))
        guard let globalHotKeyManager else {
            throw GlobalShortcutSettingsError.unavailable
        }

        let result = globalHotKeyManager.reconfigure(shortcuts: shortcuts)
        guard result.succeeded else {
            let failure = Self.shortcutFailureMessage(for: result.startResult)
            if result.rollbackSucceeded {
                // The candidate failed, but the previously working set is
                // active again. Surface the rejected candidate through the
                // thrown error without leaving a stale global warning behind.
                globalShortcutWarning = nil
                Self.logger.error("Global shortcut update rejected and previous bindings restored")
                throw GlobalShortcutSettingsError.registrationFailed(failure)
            }

            let rollbackFailure: String
            if let rollbackResult = result.rollbackStartResult {
                rollbackFailure = Self.shortcutFailureMessage(for: rollbackResult)
            } else {
                rollbackFailure = "没有可恢复的旧配置"
            }
            let message = "\(failure)。原快捷键也未能恢复：\(rollbackFailure)；当前已配置的全局快捷键均未启用"
            globalShortcutWarning = message
            Self.logger.fault("Global shortcut update and rollback both failed")
            throw GlobalShortcutSettingsError.rollbackFailed(message)
        }

        globalShortcuts = shortcuts
        UserDefaults.standard.set(encoded, forKey: Self.globalToolShortcutsDefaultsKey)
        globalShortcutWarning = nil
        notice = "新的全局快捷键已启用"
    }

    func setGlobalShortcutRecordingActive(_ active: Bool) {
        guard active != isGlobalShortcutRecordingActive else { return }
        isGlobalShortcutRecordingActive = active

        guard let globalHotKeyManager else { return }
        if active {
            globalHotKeyManager.stop()
            return
        }

        let result = globalHotKeyManager.start(shortcuts: globalShortcuts)
        globalShortcutWarning = result.succeeded
            ? nil
            : Self.inactiveShortcutSetMessage(for: result)
    }

    private func performGlobalShortcut(_ command: GlobalShortcutCommand) {
        if let mode = command.screenshotMode {
            capture(mode)
            return
        }

        switch command {
        case .recordCurrentDisplay:
            toggleRecordingFromShortcut(.currentDisplay)
        case .recordRegion:
            toggleRecordingFromShortcut(.region)
        case .recordWindow:
            toggleRecordingFromShortcut(.window)
        case .pickColor:
            sampleAndCopyColor()
        case .translateText:
            translateSelectedTextFromShortcut()
        case .screenshotRegion, .screenshotWindow, .screenshotScreen,
             .screenshotDelayed, .screenshotFramed, .screenshotMultiWindow,
             .screenshotScrolling:
            break
        }
    }

    func presentTextTranslation() {
        textTranslationLaunchRequest = nil
        selectedDestination = .translation
        presentMainWindow()
    }

    func presentImageCompression() {
        selectedDestination = .imageCompression
        presentMainWindow()
    }

    func presentImageCompression(importing urls: [URL]) {
        presentImageCompression()
        imageCompression.addImagesFromExternalOpen(urls)
    }

    func presentMainWindow() {
        mainWindowOpenRequestID &+= 1
    }

    func claimMainWindowOpenRequest(_ requestID: Int) -> Bool {
        guard requestID > lastClaimedMainWindowOpenRequestID else { return false }
        lastClaimedMainWindowOpenRequestID = requestID
        return true
    }

    func consumeTextTranslationLaunchRequest(_ requestID: UUID) {
        guard textTranslationLaunchRequest?.id == requestID else { return }
        textTranslationLaunchRequest = nil
    }

    private func translateSelectedTextFromShortcut() {
        // Resolve the target application before any async work. OnePaw only
        // activates its own window after the selection has been captured.
        let applicationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        selectedTextTranslationTask?.cancel()
        selectedTextTranslationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await selectedTextCaptureService.capture(
                applicationPID: applicationPID
            )
            guard !Task.isCancelled else { return }

            let payload: TextTranslationLaunchRequest.Payload
            switch result {
            case .selected(let text):
                if let direction = QuickTranslationDirectionResolver.direction(for: text) {
                    payload = .translate(text: text, direction: direction)
                } else {
                    payload = .message("选中的内容没有可识别的中文或英文，请重新选择文字后再按快捷键。")
                }
            case .permissionRequired:
                payload = .message(
                    "快捷翻译需要辅助功能权限。请在“系统设置 → 隐私与安全性 → 辅助功能”允许一爪，授权后重新按快捷键。"
                )
            case .noSelection:
                payload = .message("没有读取到选中文字。请先在其他 App 中选中一段中文或英文，再按快捷键。")
            case .unavailable:
                payload = .message(
                    "当前 App 没有向 macOS 提供选中文字。可以先复制文字，再在翻译页点击“粘贴”。"
                )
            }

            textTranslationLaunchRequest = TextTranslationLaunchRequest(payload: payload)
            selectedDestination = .translation
            presentMainWindow()
            selectedTextTranslationTask = nil
        }
    }

    private func toggleRecordingFromShortcut(_ source: ScreenRecordingSource) {
        switch screenRecording.state {
        case .idle, .completed, .cancelled, .failed:
            startRecording(source)
        case .choosingSource, .starting:
            guard screenRecording.activeSource == source else {
                notice = recordingShortcutConflictMessage(requested: source)
                return
            }
            cancelRecording()
            notice = "正在取消\(source.title)"
        case .recording:
            guard screenRecording.activeSource == source else {
                notice = recordingShortcutConflictMessage(requested: source)
                return
            }
            stopRecording()
            notice = "正在停止并保存录屏…"
        case .stopping:
            notice = "正在保存录屏，请稍候"
        }
    }

    private func recordingShortcutConflictMessage(requested: ScreenRecordingSource) -> String {
        guard let activeSource = screenRecording.activeSource else {
            return "已有录屏任务正在进行，请先完成或取消"
        }
        var message = "无法开始“\(requested.title)”：正在进行“\(activeSource.title)”。请先停止或取消"
        if let activeShortcut = configuredShortcutLabel(for: activeSource.shortcutCommand) {
            message += "；也可再次按 \(activeShortcut)"
        }
        return message
    }

    func startServer() {
        do {
            try server.start()
        } catch {
            serverState = .failed(error.localizedDescription)
            notice = "无法启动共享服务：\(error.localizedDescription)"
        }
    }

    func stopServer() {
        server.stop()
    }

    func toggleServer() {
        isServerRunning ? stopServer() : startServer()
    }

    func copyShareLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shareURL, forType: .string)
        notice = "共享链接已复制"
    }

    func applyShareAccessCode(_ rawValue: String) throws {
        let previousToken = sessionToken
        let normalizedValue = try ShareAccessCodePreferences.saveCustom(
            rawValue,
            to: defaults
        )

        router.updateSessionToken(normalizedValue)
        sessionToken = normalizedValue
        usesCustomShareAccessCode = true
        notice = normalizedValue == previousToken
            ? "已保存为自定义访问码"
            : "访问码已更新，旧链接和二维码已失效"
    }

    func resetShareAccessCode() {
        var randomValue = ShareAccessCode.makeRandom()
        while randomValue == sessionToken {
            randomValue = ShareAccessCode.makeRandom()
        }

        ShareAccessCodePreferences.clearCustom(from: defaults)
        router.updateSessionToken(randomValue)
        sessionToken = randomValue
        usesCustomShareAccessCode = false
        notice = "已换成新的随机访问码，旧链接和二维码已失效"
    }

    func openBrowserPreview() {
        guard let url = localPreviewURL else { return }
        NSWorkspace.shared.open(url)
    }

    func addFiles(_ urls: [URL]) {
        var added = 0
        var rejected = 0
        for url in urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            do {
                _ = try store.addSharedFile(at: url)
                added += 1
            } catch {
                rejected += 1
            }
        }
        if added > 0 {
            notice = "已加入 \(added) 个共享文件"
        } else if rejected > 0 {
            notice = "当前只能分享普通文件"
        }
    }

    func addText(_ text: String) -> Bool {
        do {
            _ = try store.addSharedText(text)
            notice = "文字已加入共享列表"
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }

    func removePublicItem(_ item: SharedItem) {
        let succeeded: Bool
        if item.direction == .outgoing {
            succeeded = store.removeOutgoing(id: item.id)
        } else {
            succeeded = store.hideIncomingFromPublic(id: item.id)
        }
        notice = succeeded
            ? "已从课堂共享区移除，原文件不会被删除"
            : SharedContentStoreError.persistenceFailed.localizedDescription
    }

    func publishIncoming(_ item: SharedItem) {
        let succeeded = store.publishIncoming(id: item.id)
        notice = succeeded
            ? "已重新加入课堂共享区"
            : SharedContentStoreError.persistenceFailed.localizedDescription
    }

    func clearPublicItems() {
        notice = store.clearPublicItems()
            ? "课堂共享区已清空，接收的原文件仍保留在本机"
            : SharedContentStoreError.persistenceFailed.localizedDescription
    }

    func clearInbox() {
        notice = store.clearIncoming(deleteFiles: false)
            ? "学生上传记录已移出共享区，原文件仍保留在接收箱"
            : SharedContentStoreError.persistenceFailed.localizedDescription
    }

    func openInboxDirectory() {
        NSWorkspace.shared.open(store.inboxDirectory)
    }

    func reveal(_ item: SharedItem) {
        guard let url = item.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyText(_ item: SharedItem) {
        guard let text = item.detail else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notice = "文字已复制"
    }

    func sampleAndCopyColor() {
        guard !isPreparingColorSampling, !colorSampler.isSampling else { return }
        guard !bringColorSamplingBlockingWindowToFrontIfNeeded() else {
            notice = "请先关闭当前弹窗，再开始取色"
            return
        }
        guard !screenRecording.isBusy else {
            notice = "请先停止或取消当前录屏"
            return
        }
        guard !isCapturing else {
            notice = "请先完成当前截图"
            return
        }

        isPreparingColorSampling = true
        Task {
            // Realtime sampling excludes OnePaw from ScreenCaptureKit. Hide
            // OnePaw's windows first so the pixels under the pointer match
            // what the user can actually see, including over image pins.
            let hiddenWindows = TemporarilyHiddenAppWindows()
            defer {
                hiddenWindows.restore()
                isPreparingColorSampling = false
            }
            NSApp.deactivate()
            try? await Task.sleep(for: .milliseconds(120))
            if let color = await colorSampler.sampleAndCopyHex() {
                notice = "已提取并复制 \(color.hexText)"
            } else {
                notice = colorSampler.statusMessage
            }
        }
    }

    func beginColorSampling() {
        guard !isPreparingColorSampling, !colorSampler.isSampling else { return }
        guard !bringColorSamplingBlockingWindowToFrontIfNeeded() else {
            notice = "请先关闭当前弹窗，再开始取色"
            return
        }
        guard !screenRecording.isBusy else {
            notice = "请先停止或取消当前录屏"
            return
        }
        guard !isCapturing else {
            notice = "请先完成当前截图"
            return
        }

        isPreparingColorSampling = true
        Task {
            let hiddenWindows = TemporarilyHiddenAppWindows()
            defer {
                hiddenWindows.restore()
                isPreparingColorSampling = false
            }
            NSApp.deactivate()
            try? await Task.sleep(for: .milliseconds(120))
            if let color = await colorSampler.beginSampling() {
                notice = "已提取 \(color.hexText)"
            } else {
                notice = colorSampler.statusMessage
            }
        }
    }

    /// Full-screen sampling temporarily orders out OnePaw windows. Refuse to
    /// start while a sheet or modal panel is visible so that AppKit keeps its
    /// parent/child window relationship intact and no dialog is lost.
    private func bringColorSamplingBlockingWindowToFrontIfNeeded() -> Bool {
        if let modalWindow = NSApp.modalWindow, modalWindow.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            modalWindow.orderFrontRegardless()
            return true
        }

        if let sheet = NSApp.windows.first(where: {
            $0.isVisible && $0.sheetParent != nil
        }) {
            NSApp.activate(ignoringOtherApps: true)
            sheet.sheetParent?.makeKeyAndOrderFront(nil)
            sheet.orderFrontRegardless()
            return true
        }

        if let parent = NSApp.windows.first(where: {
            $0.isVisible && $0.attachedSheet?.isVisible == true
        }) {
            NSApp.activate(ignoringOtherApps: true)
            parent.makeKeyAndOrderFront(nil)
            parent.attachedSheet?.orderFrontRegardless()
            return true
        }

        return false
    }

    func startRecording(_ source: ScreenRecordingSource) {
        if let screenshotEditorWindowController {
            screenshotEditorWindowController.bringToFront()
            notice = "请先完成当前截图的编辑，再开始录屏"
            return
        }
        guard !isCapturing else {
            notice = "请先完成当前截图"
            return
        }
        guard !isPreparingColorSampling, !colorSampler.isSampling else {
            notice = "请先完成或取消取色"
            return
        }
        guard !screenRecording.isBusy else {
            notice = "已有录屏任务正在进行"
            return
        }

        let isAuthorized = screenshotService.hasPermission
        hasScreenCapturePermission = isAuthorized
        guard isAuthorized else {
            notice = "录屏需要“屏幕与系统音频录制”权限，授权并完全退出重开后再试"
            requestScreenCapturePermission()
            return
        }

        screenRecording.start(source)
    }

    func stopRecording() {
        screenRecording.stop()
    }

    func cancelRecording() {
        screenRecording.cancel()
    }

    func shareRecording(_ url: URL) {
        guard url.standardizedFileURL.deletingLastPathComponent()
            == screenRecording.recordingsDirectory.standardizedFileURL else {
            notice = "只能分享一爪已完成的录屏文件"
            return
        }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                notice = "录屏文件不存在或尚未完成"
                return
            }
            let size = Int64(values.fileSize ?? 0)
            guard size <= ScreenRecordingFeatureModel.classroomShareLimitBytes else {
                notice = "录屏超过 256 MB，当前版本不会把它加入课堂共享"
                return
            }
            _ = try store.addSharedFile(at: url)
            notice = "录屏已加入课堂共享区"
        } catch {
            notice = "无法分享录屏：\(error.localizedDescription)"
        }
    }

    func recordingWasDeleted(_ url: URL) {
        let removedShares = store.removeOutgoingFiles(at: url)
        notice = removedShares > 0
            ? "录屏文件已删除，并已从课堂共享区移除"
            : "录屏文件已从本机删除"
    }

    func capture(_ mode: ScreenshotMode) {
        guard !screenRecording.isBusy else {
            notice = "请先停止或取消当前录屏"
            return
        }
        guard !isPreparingColorSampling, !colorSampler.isSampling else {
            notice = "请先完成或取消取色"
            return
        }
        if let screenshotEditorWindowController {
            screenshotEditorWindowController.bringToFront()
            notice = "请先完成当前截图的编辑"
            return
        }
        guard !isCapturing else { return }

        if !mode.requiresPersistentScreenCapturePermission {
            beginCapture(mode)
            return
        }

        let isAuthorized = screenshotService.hasPermission
        hasScreenCapturePermission = isAuthorized
        switch screenCapturePermissionGate.nextAction(isAuthorized: isAuthorized) {
        case .capture:
            beginCapture(mode)
        case .requestPermission:
            performScreenCapturePermissionRequest(pendingCapture: mode)
        case .showSettingsGuidance:
            presentScreenCaptureSettingsGuidance()
        }
    }

    private func beginCapture(_ mode: ScreenshotMode) {
        guard !isCapturing else { return }
        isCapturing = true
        switch mode {
        case .delayedScreen:
            notice = "5 秒后截取鼠标所在屏幕，可在倒计时窗口中取消"
        case .framedScreen:
            notice = "3 秒后截取整屏并加入一爪 Mac 外框"
        case .multiWindow:
            notice = "请在系统选择器中勾选要合成的多个窗口"
        case .scrolling:
            notice = "一爪将暂时隐藏；只框选可滚动内容，随后在蓝框内平稳滚动"
        case .region, .window, .screen:
            notice = nil
        }
        Task {
            defer { isCapturing = false }
            do {
                let url = try await screenshotService.capture(mode)
                let automaticCopyError: String?
                do {
                    let pngData = try Data(contentsOf: url, options: .mappedIfSafe)
                    try screenshotPasteboardWriter.writePNG(pngData, tiffData: nil)
                    automaticCopyError = nil
                } catch {
                    automaticCopyError = error.localizedDescription
                }
                presentScreenshotEditor(
                    draftURL: url,
                    originalWasAutomaticallyCopied: automaticCopyError == nil,
                    automaticCopyError: automaticCopyError
                )
            } catch ScreenshotServiceError.cancelled {
                notice = "已取消截图"
            } catch ScreenshotServiceError.permissionDenied {
                hasScreenCapturePermission = false
                notice = "截图权限尚未生效。若刚刚已允许，请完全退出并重新打开一爪；否则请在系统设置中开启"
            } catch {
                notice = "截图失败：\(error.localizedDescription)"
            }
        }
    }

    private func presentScreenshotEditor(
        draftURL: URL,
        originalWasAutomaticallyCopied: Bool,
        automaticCopyError: String?
    ) {
        do {
            let controller = try ScreenshotEditorWindowController(
                sourceURL: draftURL,
                originalWasAutomaticallyCopied: originalWasAutomaticallyCopied,
                onPinImage: { [weak self] image in
                    guard let self else {
                        throw CocoaError(.featureUnsupported)
                    }
                    let editorWindow = self.screenshotEditorWindowController?.window
                    let shouldSelectPinForKeyboard = NSApp.isActive
                        && editorWindow?.isKeyWindow == true
                        && editorWindow?.attachedSheet == nil
                    _ = try self.pinnedScreenshotManager.pin(
                        image: image,
                        targetScreen: editorWindow?.screen,
                        selectForKeyboard: shouldSelectPinForKeyboard
                    )
                    self.notice = "截图已固定为小贴图，可以继续操作其他应用"
                },
                onSharePNG: { [weak self] pngData in
                    guard let self else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try self.publishEditedScreenshot(pngData)
                },
                onClose: { [weak self] in
                    self?.finishScreenshotEditing(draftURL: draftURL)
                }
            )
            screenshotEditorWindowController = controller
            if let automaticCopyError {
                notice = "截图已完成，但自动复制失败：\(automaticCopyError)。编辑器已打开，可点击“复制图片”重试"
            } else {
                notice = "截图已自动复制到剪贴板，可以继续标注或直接粘贴"
            }
            if controller.show() {
                // The editor replaces the main window for this interaction.
                // Close the retained main window after it has been ordered out
                // so dismissing the editor cannot reveal it underneath.
                mainWindowDismissRequestID &+= 1
            }
        } catch {
            removeScreenshotDraft(at: draftURL)
            if originalWasAutomaticallyCopied {
                notice = "截图已复制到剪贴板，但无法打开截图编辑器：\(error.localizedDescription)"
            } else if let automaticCopyError {
                notice = "截图自动复制失败（\(automaticCopyError)），且无法打开截图编辑器：\(error.localizedDescription)"
            } else {
                notice = "无法打开截图编辑器：\(error.localizedDescription)"
            }
        }
    }

    private func publishEditedScreenshot(_ pngData: Data) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let filename = "截图 \(formatter.string(from: Date())) \(suffix)-已编辑.png"
        let destination = screenshotsDirectory.appendingPathComponent(filename)

        do {
            try pngData.write(to: destination, options: .atomic)
            do {
                _ = try store.addSharedFile(at: destination)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            notice = "编辑后的截图已加入课堂共享区"
        } catch {
            throw error
        }
    }

    private func finishScreenshotEditing(draftURL: URL) {
        screenshotEditorWindowController = nil
        removeScreenshotDraft(at: draftURL)
    }

    private func removeScreenshotDraft(at url: URL) {
        let expectedParent = screenshotDraftsDirectory.standardizedFileURL
        guard url.deletingLastPathComponent().standardizedFileURL == expectedParent else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    func refreshScreenCapturePermission() {
        hasScreenCapturePermission = screenshotService.hasPermission
    }

    func requestScreenCapturePermission() {
        let isAuthorized = screenshotService.hasPermission
        hasScreenCapturePermission = isAuthorized
        switch screenCapturePermissionGate.nextAction(isAuthorized: isAuthorized) {
        case .capture:
            notice = "截图权限已生效，可以开始截图"
        case .requestPermission:
            performScreenCapturePermissionRequest()
        case .showSettingsGuidance:
            presentScreenCaptureSettingsGuidance()
        }
    }

    private func performScreenCapturePermissionRequest(pendingCapture mode: ScreenshotMode? = nil) {
        guard !isCapturing else { return }
        if screenshotService.hasPermission {
            hasScreenCapturePermission = true
            notice = "截图权限已生效，可以开始截图"
            if let mode {
                beginCapture(mode)
            }
            return
        }

        screenCapturePermissionGate.markRequestAttempted()
        isCapturing = true
        notice = nil
        NSApp.activate(ignoringOtherApps: true)
        Task {
            let requestResult = await screenshotService.requestPermission()
            hasScreenCapturePermission = screenshotService.hasPermission
            isCapturing = false

            if hasScreenCapturePermission {
                notice = "截图权限已生效，可以开始截图"
                if let mode {
                    beginCapture(mode)
                }
            } else {
                switch requestResult {
                case .contentAvailable:
                    notice = "已允许截图权限，请完全退出并重新打开一爪后再截图"
                case .userDeclined:
                    presentScreenCaptureSettingsGuidance()
                case .failed(let message):
                    notice = "无法申请截图权限：\(message)"
                }
            }
        }
    }

    private func presentScreenCaptureSettingsGuidance() {
        notice = "请在系统设置的录屏权限页开启一爪，完成后完全退出并重新打开 App"
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "需要在系统设置中开启截图权限"
        alert.informativeText = "macOS 尚未授予一爪截图权限。如果刚才没有出现授权框，或你之前选择过“不允许”，请在列表中开启它。列表里没有一爪时，请点“+”并选择：\n\(Bundle.main.bundleURL.path)\n\n开启后，请完全退出并重新打开一爪。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            openScreenCaptureSettings()
        }
    }

    func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func refreshItems(announcesNewIncoming: Bool) {
        sharedItems = store.outgoingSnapshot()
        receivedItems = store.incomingSnapshot()
        publicItems = store.publicSnapshot()
        if announcesNewIncoming,
           let newest = receivedItems.first,
           Date().timeIntervalSince(newest.createdAt) < 2 {
            let title = newest.kind == .text ? "收到一段文字" : "收到文件：\(newest.title)"
            notice = title
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    private static let globalToolShortcutsDefaultsKey = "globalToolShortcuts.v1"
    private static let legacyScreenshotShortcutsDefaultsKey = "globalScreenshotShortcuts.v1"

    private static func loadGlobalShortcuts() -> GlobalShortcutLoadResult {
        if let data = UserDefaults.standard.data(forKey: globalToolShortcutsDefaultsKey),
           let persisted = try? JSONDecoder().decode(PersistedGlobalToolShortcuts.self, from: data),
           persisted.version == PersistedGlobalToolShortcuts.currentVersion,
           let prepared = prepareLoadedGlobalShortcuts(
               persisted.shortcuts,
               shouldPersist: false
           ) {
            return prepared
        }

        guard let legacyData = UserDefaults.standard.data(
            forKey: legacyScreenshotShortcutsDefaultsKey
        ) else {
            return GlobalShortcutLoadResult(
                shortcuts: GlobalShortcutCommand.defaultGlobalShortcuts,
                migrationNotice: nil,
                shouldPersist: false
            )
        }

        // Builds 6...11 stored a version-2 binding dictionary keyed by the
        // ScreenshotMode raw value. Preserve every customized screenshot key
        // and leave the newly introduced recording and color commands unbound.
        if let persisted = try? JSONDecoder().decode(
            LegacyPersistedScreenshotShortcutsV2.self,
            from: legacyData
        ), persisted.version == LegacyPersistedScreenshotShortcutsV2.currentVersion {
            if let prepared = prepareLoadedGlobalShortcuts(
                persisted.commandShortcuts,
                shouldPersist: true
            ) {
                return prepared
            }
        }

        // Build 5 stored the first three screenshot shortcuts as explicit
        // fields. They map directly to the three required command bindings.
        if let legacy = try? JSONDecoder().decode(
            LegacyPersistedScreenshotShortcutsV1.self,
            from: legacyData
        ), legacy.version == 1,
           let prepared = prepareLoadedGlobalShortcuts(
               legacy.commandShortcuts,
               shouldPersist: true
           ) {
            return prepared
        }

        return GlobalShortcutLoadResult(
            shortcuts: GlobalShortcutCommand.defaultGlobalShortcuts,
            migrationNotice: nil,
            shouldPersist: false
        )
    }

    private static func prepareLoadedGlobalShortcuts(
        _ shortcuts: [GlobalShortcutCommand: GlobalShortcut],
        shouldPersist: Bool
    ) -> GlobalShortcutLoadResult? {
        guard let migration = GlobalShortcutCommand.migratingUnsafeCommandOnlyBindings(
            shortcuts,
            requiredCommands: GlobalShortcutCommand.requiredGlobalShortcutCommands,
            fallbackCandidates: safeShortcutMigrationCandidates
        ), GlobalHotKeyManager.validate(shortcuts: migration.shortcuts).isEmpty else {
            return nil
        }

        guard migration.didChange else {
            return GlobalShortcutLoadResult(
                shortcuts: migration.shortcuts,
                migrationNotice: nil,
                shouldPersist: shouldPersist
            )
        }

        var noticeParts: [String] = []
        if !migration.resetCommands.isEmpty {
            noticeParts.append(
                "已为 \(migration.resetCommands.map(\.title).joined(separator: "、")) 换成安全组合"
            )
        }
        if !migration.clearedCommands.isEmpty {
            noticeParts.append(
                "已清除 \(migration.clearedCommands.map(\.title).joined(separator: "、")) 的旧组合"
            )
        }
        let notice = "旧版仅使用 ⌘ 的全局快捷键可能抢占其他 App；\(noticeParts.joined(separator: "；"))，其余设置已保留"
        return GlobalShortcutLoadResult(
            shortcuts: migration.shortcuts,
            migrationNotice: notice,
            shouldPersist: true
        )
    }

    private static var safeShortcutMigrationCandidates: [GlobalShortcut] {
        let preferred = [
            GlobalShortcutCommand.defaultGlobalShortcuts[.screenshotRegion],
            GlobalShortcutCommand.defaultGlobalShortcuts[.screenshotWindow],
            GlobalShortcutCommand.defaultGlobalShortcuts[.screenshotScreen],
        ].compactMap { $0 }
        let additionalKeyCodes: [UInt32] = [
            21, 23, 22, 26, 28, 25, 29,
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17,
        ]
        let candidates = preferred + additionalKeyCodes.map {
            GlobalShortcut(keyCode: $0, modifiers: [.control, .shift])
        }
        return candidates
    }

    private static func shortcutFailureMessage(
        for result: GlobalHotKeyManager.StartResult
    ) -> String {
        if !result.validationIssues.isEmpty {
            return "快捷键配置无效：\(result.validationIssues.map(\.message).joined(separator: "；"))"
        }
        guard result.handlerStatus == noErr else {
            return "系统无法启用全局快捷键（错误码 \(result.handlerStatus)）"
        }

        let failedRegistrations = result.registrations.filter { !$0.succeeded }
        guard !failedRegistrations.isEmpty else {
            return "系统无法完整启用全局快捷键"
        }

        let labels = failedRegistrations
            .map { $0.shortcut.displayLabel }
            .joined(separator: "、")
        let codes = Array(Set(failedRegistrations.map(\.status)))
            .sorted()
            .map(String.init)
            .joined(separator: ", ")
        return "快捷键 \(labels) 无法启用，可能已被另一个一爪、macOS 或其他应用占用（错误码 \(codes)）"
    }

    private static func inactiveShortcutSetMessage(
        for result: GlobalHotKeyManager.StartResult
    ) -> String {
        "\(shortcutFailureMessage(for: result))；为避免部分生效，当前已配置的全局快捷键均未启用"
    }

    private static func makeDirectories() -> (inbox: URL, screenshots: URL, drafts: URL) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("crosstool", isDirectory: true)
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        let screenshots = root.appendingPathComponent("Screenshots", isDirectory: true)
        let drafts = screenshots.appendingPathComponent("Drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
        return (inbox, screenshots, drafts)
    }

    private static func removeStaleScreenshotDrafts(in directory: URL) {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let expirationDate = Date().addingTimeInterval(-24 * 60 * 60)
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt < expirationDate else {
                continue
            }
            try? fileManager.removeItem(at: url)
        }
    }

    private static func loadWebResources() -> (index: Data, assets: [String: StaticWebAsset]) {
        let index = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "Web")
            .flatMap { try? Data(contentsOf: $0) }
            ?? Data("<!doctype html><meta charset=\"utf-8\"><h1>一爪</h1>".utf8)

        var assets: [String: StaticWebAsset] = [:]
        if let cssURL = Bundle.module.url(forResource: "app", withExtension: "css", subdirectory: "Web"),
           let data = try? Data(contentsOf: cssURL) {
            assets["/assets/app.css"] = StaticWebAsset(data: data, contentType: "text/css; charset=utf-8")
        }
        if let jsURL = Bundle.module.url(forResource: "app", withExtension: "js", subdirectory: "Web"),
           let data = try? Data(contentsOf: jsURL) {
            assets["/assets/app.js"] = StaticWebAsset(data: data, contentType: "text/javascript; charset=utf-8")
        }
        return (index, assets)
    }
}

private struct GlobalShortcutLoadResult {
    let shortcuts: [GlobalShortcutCommand: GlobalShortcut]
    let migrationNotice: String?
    let shouldPersist: Bool
}

private struct PersistedGlobalToolShortcuts: Codable {
    static let currentVersion = 1

    let version: Int
    let bindings: [String: GlobalShortcut]

    init(_ shortcuts: [GlobalShortcutCommand: GlobalShortcut]) {
        version = Self.currentVersion
        bindings = GlobalShortcutCommand.persistedBindings(from: shortcuts)
    }

    var shortcuts: [GlobalShortcutCommand: GlobalShortcut] {
        GlobalShortcutCommand.shortcuts(fromPersistedBindings: bindings)
    }
}

private struct LegacyPersistedScreenshotShortcutsV2: Codable {
    static let currentVersion = 2

    let version: Int
    let bindings: [String: GlobalShortcut]

    var commandShortcuts: [GlobalShortcutCommand: GlobalShortcut] {
        Dictionary(uniqueKeysWithValues: bindings.compactMap { rawMode, shortcut in
            guard let mode = ScreenshotMode(rawValue: rawMode) else { return nil }
            return (mode.shortcutCommand, shortcut)
        })
    }
}

private struct LegacyPersistedScreenshotShortcutsV1: Codable {
    let version: Int
    let region: GlobalShortcut
    let window: GlobalShortcut
    let screen: GlobalShortcut

    var commandShortcuts: [GlobalShortcutCommand: GlobalShortcut] {
        [
            .screenshotRegion: region,
            .screenshotWindow: window,
            .screenshotScreen: screen,
        ]
    }
}

private enum GlobalShortcutSettingsError: LocalizedError {
    case invalid(String)
    case unavailable
    case registrationFailed(String)
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message),
             .registrationFailed(let message),
             .rollbackFailed(let message):
            return message
        case .unavailable:
            return "全局快捷键服务暂时不可用，请重新打开一爪后再试"
        }
    }
}
