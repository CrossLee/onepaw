import AppKit
import SwiftUI

private struct ScreenshotEditorLoadingView: View {
    let metadata: ScreenshotEditorImageMetadata
    let failureMessage: String?

    var body: some View {
        VStack(spacing: 14) {
            if let failureMessage {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.orange)
                Text("无法载入截图")
                    .font(.headline)
                Text(failureMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Text("请关闭窗口后重新截图")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView()
                    .controlSize(.regular)
                Text("正在载入截图…")
                    .font(.headline)
                Text("原图尺寸 \(metadata.pixelWidth) × \(metadata.pixelHeight)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

enum ScreenshotEditorPinShortcut {
    enum Decision: Equatable {
        case ignore
        case consume
        case performPin
    }

    private static let disallowedModifiers: NSEvent.ModifierFlags = [
        .command,
        .control,
        .option,
        .shift,
        .function
    ]

    static func isBareSKeyDown(_ event: NSEvent) -> Bool {
        event.type == .keyDown
            && event.modifierFlags.intersection(disallowedModifiers).isEmpty
            && event.charactersIgnoringModifiers?.lowercased() == "s"
    }

    static func decision(
        for event: NSEvent,
        isKeyWindow: Bool,
        hasAttachedSheet: Bool,
        isEditingText: Bool
    ) -> Decision {
        guard isKeyWindow,
              !hasAttachedSheet,
              !isEditingText,
              isBareSKeyDown(event) else {
            return .ignore
        }
        return event.isARepeat ? .consume : .performPin
    }
}

enum ScreenshotEditorCopyShortcut {
    enum Decision: Equatable {
        case ignore
        case forwardToTextResponder
        case consume
        case copyImage
    }

    static func decision(
        for event: NSEvent,
        isKeyWindow: Bool,
        hasAttachedSheet: Bool,
        hasSelectedText: Bool,
        isEditingText: Bool
    ) -> Decision {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.type == .keyDown,
              isKeyWindow,
              !hasAttachedSheet,
              modifiers == .command,
              event.charactersIgnoringModifiers?.lowercased() == "c" else {
            return .ignore
        }
        if isEditingText || hasSelectedText {
            return .forwardToTextResponder
        }
        return event.isARepeat ? .consume : .copyImage
    }
}

enum ScreenshotEditorTextEditingEscapeShortcut {
    enum Phase: Equatable {
        case keyDown
        case keyUp
    }

    private static let disallowedModifiers: NSEvent.ModifierFlags = [
        .command,
        .control,
        .option,
        .shift,
        .function,
    ]

    static func phase(for event: NSEvent) -> Phase? {
        // NSEvent.keyCode is only valid for key events. Reading it from a
        // mouse event raises an AppKit assertion and prevents that event from
        // reaching the SwiftUI canvas.
        guard event.type == .keyDown || event.type == .keyUp else {
            return nil
        }
        guard event.keyCode == 53,
              event.modifierFlags.intersection(disallowedModifiers).isEmpty else {
            return nil
        }
        return event.type == .keyDown ? .keyDown : .keyUp
    }
}

@MainActor
final class ScreenshotEditorWindow: NSWindow {
    var onBareSPin: (() -> Void)?
    var onCommandCCopyImage: (() -> Void)?
    var isTextAnnotationEditing: (() -> Bool)?
    var onCancelTextEditing: (() -> Bool)?
    private var consumesTextEditingEscapeUntilKeyUp = false

    override func sendEvent(_ event: NSEvent) {
        let textView = firstResponder as? NSTextView
        if handleTextEditingEscape(event, textView: textView) {
            return
        }
        let isEditingText = textView?.isEditable == true
            || isTextAnnotationEditing?() == true
        switch ScreenshotEditorCopyShortcut.decision(
            for: event,
            isKeyWindow: isKeyWindow,
            hasAttachedSheet: attachedSheet != nil,
            hasSelectedText: (textView?.selectedRange().length ?? 0) > 0,
            isEditingText: isEditingText
        ) {
        case .ignore:
            break
        case .forwardToTextResponder:
            super.sendEvent(event)
            return
        case .consume:
            return
        case .copyImage:
            guard let onCommandCCopyImage else {
                super.sendEvent(event)
                return
            }
            onCommandCCopyImage()
            return
        }

        switch ScreenshotEditorPinShortcut.decision(
            for: event,
            isKeyWindow: isKeyWindow,
            hasAttachedSheet: attachedSheet != nil,
            isEditingText: isEditingText
        ) {
        case .ignore:
            super.sendEvent(event)
        case .consume:
            // Keep auto-repeat from leaking into the responder chain while the
            // editor stays open after a failed pin attempt.
            return
        case .performPin:
            guard let onBareSPin else {
                super.sendEvent(event)
                return
            }
            onBareSPin()
        }
    }

    private func handleTextEditingEscape(
        _ event: NSEvent,
        textView: NSTextView?
    ) -> Bool {
        guard let phase = ScreenshotEditorTextEditingEscapeShortcut.phase(for: event) else {
            return false
        }
        if phase == .keyUp, consumesTextEditingEscapeUntilKeyUp {
            consumesTextEditingEscapeUntilKeyUp = false
            return true
        }
        guard phase == .keyDown else { return false }
        if consumesTextEditingEscapeUntilKeyUp {
            return true
        }
        guard isKeyWindow,
              attachedSheet == nil,
              isTextAnnotationEditing?() == true else {
            return false
        }
        if textView?.hasMarkedText() == true {
            return false
        }
        guard onCancelTextEditing?() == true else { return false }
        consumesTextEditingEscapeUntilKeyUp = true
        makeFirstResponder(nil)
        return true
    }
}

@MainActor
final class ScreenshotEditorMainWindowSession {
    private var hiddenWindows: [NSWindow]

    var didHideMainWindow: Bool {
        !hiddenWindows.isEmpty
    }

    static func shouldHide(
        isEditorWindow: Bool,
        title: String,
        isVisible: Bool,
        isMiniaturized: Bool,
        canBecomeMain: Bool,
        isTitled: Bool,
        hasAttachedSheet: Bool
    ) -> Bool {
        !isEditorWindow
            && title == ApplicationBrand.displayName
            && isVisible
            && !isMiniaturized
            && canBecomeMain
            && isTitled
            && !hasAttachedSheet
    }

    convenience init(editorWindow: NSWindow) {
        self.init(
            editorWindow: editorWindow,
            applicationWindows: NSApp.windows
        )
    }

    init(
        editorWindow: NSWindow,
        applicationWindows: [NSWindow]
    ) {
        hiddenWindows = applicationWindows.filter { window in
            Self.shouldHide(
                isEditorWindow: window === editorWindow
                    || window is ScreenshotEditorWindow,
                title: window.title,
                isVisible: window.isVisible,
                isMiniaturized: window.isMiniaturized,
                canBecomeMain: window.canBecomeMain,
                isTitled: window.styleMask.contains(.titled),
                hasAttachedSheet: window.attachedSheet != nil
            )
        }
        for window in hiddenWindows {
            window.orderOut(nil)
        }
    }

    /// The screenshot editor replaces the main window for this interaction.
    /// Keep the main window ordered out after the editor closes; the explicit
    /// menu-bar "Open Main Window" action can order the same SwiftUI Window
    /// back to the front later.
    func commitKeepingHidden() {
        hiddenWindows.removeAll()
    }

    /// Used only if editor presentation cannot complete after the main window
    /// has already been hidden. Restoring is deliberately idempotent.
    func restore() {
        let windows = hiddenWindows
        hiddenWindows.removeAll()
        for window in windows {
            window.orderFront(nil)
        }
    }
}

@MainActor
final class ScreenshotEditorWindowController: NSWindowController, NSWindowDelegate {
    typealias ShareHandler = @MainActor (Data) throws -> Void
    typealias PinHandler = @MainActor (CGImage) throws -> Void
    typealias CloseHandler = @MainActor () -> Void
    typealias ImageLoader = @Sendable (URL) async throws -> ScreenshotEditorDecodedImage

    private let sourceURL: URL
    private let imageMetadata: ScreenshotEditorImageMetadata
    private let originalWasAutomaticallyCopied: Bool
    private let onPinImage: PinHandler?
    private let onSharePNG: ShareHandler
    private let imageLoader: ImageLoader
    private var editorModel: ScreenshotEditorViewModel?
    private let pinButton: NSButton
    private var onClose: CloseHandler?
    private var imageLoadingTask: Task<Void, Never>?
    private(set) var imageLoadErrorMessage: String?
    private var allowsClose = false
    private var closeConfirmationIsVisible = false
    private var isClosing = false

    var isEditorReady: Bool {
        editorModel != nil
    }

    init(
        sourceURL: URL,
        originalWasAutomaticallyCopied: Bool = false,
        onPinImage: PinHandler? = nil,
        onSharePNG: @escaping ShareHandler,
        onClose: @escaping CloseHandler,
        imageLoader: @escaping ImageLoader = { imageURL in
            try await ScreenshotEditorRenderer.decodeImage(at: imageURL)
        }
    ) throws {
        let imageMetadata = try ScreenshotEditorRenderer.imageMetadata(at: sourceURL)
        self.sourceURL = sourceURL
        self.imageMetadata = imageMetadata
        self.originalWasAutomaticallyCopied = originalWasAutomaticallyCopied
        self.onPinImage = onPinImage
        self.onSharePNG = onSharePNG
        self.imageLoader = imageLoader
        pinButton = NSButton()
        self.onClose = onClose

        let hostingController = NSHostingController(rootView: ScreenshotEditorLoadingView(
            metadata: imageMetadata,
            failureMessage: nil
        ))
        let window = ScreenshotEditorWindow(contentViewController: hostingController)
        window.title = "编辑截图 — 一爪"
        window.setContentSize(NSSize(width: 1120, height: 760))
        window.minSize = NSSize(width: 880, height: 580)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false

        super.init(window: window)
        window.delegate = self
        installPinButton()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @discardableResult
    func show() -> Bool {
        guard let window else { return false }
        window.center()
        bringToFront()
        // Activating the app can reorder an already-open SwiftUI Window back
        // onto the screen. Hide it only after the editor is key and visible so
        // closing the editor cannot reveal the main OnePaw window underneath.
        let mainWindowSession = ScreenshotEditorMainWindowSession(
            editorWindow: window
        )
        let didHideMainWindow = mainWindowSession.didHideMainWindow
        mainWindowSession.commitKeepingHidden()
        return didHideMainWindow
    }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        startImageLoadingIfNeeded()
    }

    func waitUntilImageLoadFinishes() async {
        let task = imageLoadingTask
        await task?.value
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let hasDeliveredOutput = editorModel?.hasDeliveredOutput
            ?? originalWasAutomaticallyCopied
        guard !allowsClose, !hasDeliveredOutput else {
            return true
        }
        guard !closeConfirmationIsVisible else { return false }
        closeConfirmationIsVisible = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        if editorModel?.hasAnyDeliveredOutput ?? originalWasAutomaticallyCopied {
            alert.messageText = "关闭并放弃尚未输出的标注？"
            alert.informativeText = "原始截图已自动复制到剪贴板，但当前标注尚未复制、保存或加入课堂共享区。关闭后会删除本次临时截图和标注。"
        } else {
            alert.messageText = editorModel?.hasAnnotations == true
                ? "关闭并放弃本次截图和标注？"
                : "关闭并放弃本次截图？"
            alert.informativeText = "这张截图尚未复制、保存或加入课堂共享区。关闭后会删除本次临时截图。"
        }
        alert.addButton(withTitle: "继续编辑")
        alert.addButton(withTitle: "放弃并关闭")
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard let self else { return }
            self.closeConfirmationIsVisible = false
            guard response == .alertSecondButtonReturn else { return }
            self.allowsClose = true
            sender?.performClose(nil)
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        isClosing = true
        imageLoadingTask?.cancel()
        imageLoadingTask = nil
        editorModel?.cancelTextRecognition()
        editorModel?.cancelInteraction()
        if let editorWindow = window as? ScreenshotEditorWindow {
            editorWindow.onBareSPin = nil
            editorWindow.onCommandCCopyImage = nil
            editorWindow.isTextAnnotationEditing = nil
            editorWindow.onCancelTextEditing = nil
        }
        window?.delegate = nil
        let handler = onClose
        onClose = nil
        handler?()
    }

    private func installPinButton() {
        pinButton.setButtonType(.momentaryPushIn)
        pinButton.title = ""
        pinButton.bezelStyle = .inline
        pinButton.isBordered = false
        pinButton.imagePosition = .imageOnly
        pinButton.imageScaling = .scaleProportionallyDown
        pinButton.refusesFirstResponder = false
        pinButton.target = self
        pinButton.action = #selector(pinCurrentImage(_:))
        pinButton.translatesAutoresizingMaskIntoConstraints = false
        pinButton.setAccessibilityRole(.button)
        pinButton.setAccessibilityLabel("将当前截图贴到屏幕")
        pinButton.setAccessibilityHelp("创建只显示当前截图的小贴图并关闭编辑器，也可以按 S")
        pinButton.image = NSImage(
            systemSymbolName: "pin",
            accessibilityDescription: "贴到屏幕"
        )
        pinButton.contentTintColor = .secondaryLabelColor
        pinButton.toolTip = "贴到屏幕（S）"
        pinButton.isEnabled = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 38, height: 28))
        container.addSubview(pinButton)
        NSLayoutConstraint.activate([
            pinButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            pinButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 28),
            pinButton.heightAnchor.constraint(equalToConstant: 28)
        ])

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        accessory.view = container
        window?.addTitlebarAccessoryViewController(accessory)
    }

    @objc
    private func pinCurrentImage(_ sender: NSButton) {
        editorModel?.pinCurrentImage()
    }

    private func startImageLoadingIfNeeded() {
        guard editorModel == nil,
              imageLoadingTask == nil,
              imageLoadErrorMessage == nil,
              !isClosing else {
            return
        }

        let sourceURL = sourceURL
        let imageLoader = imageLoader
        imageLoadingTask = Task { @MainActor [weak self] in
            do {
                let decodedImage = try await imageLoader(sourceURL)
                try Task.checkCancellation()
                guard let self, !self.isClosing else { return }
                try self.installEditor(decodedImage: decodedImage)
            } catch is CancellationError {
                // Closing the window cancels any decode still in flight.
            } catch {
                guard let self, !self.isClosing else { return }
                self.presentImageLoadFailure(error)
            }
            self?.imageLoadingTask = nil
        }
    }

    private func installEditor(decodedImage: ScreenshotEditorDecodedImage) throws {
        guard let window else { return }
        let model = try ScreenshotEditorViewModel(
            sourceURL: sourceURL,
            decodedImage: decodedImage,
            originalWasAutomaticallyCopied: originalWasAutomaticallyCopied,
            onPinImage: onPinImage,
            onSharePNG: onSharePNG
        )
        editorModel = model
        model.presentingWindow = window
        model.requestClose = { [weak self] in
            self?.window?.performClose(nil)
        }

        if let editorWindow = window as? ScreenshotEditorWindow {
            editorWindow.onBareSPin = { [weak model] in
                model?.pinCurrentImage()
            }
            editorWindow.onCommandCCopyImage = { [weak model] in
                model?.copyToPasteboard()
            }
            editorWindow.isTextAnnotationEditing = { [weak model] in
                model?.activeTextEntry != nil
            }
            editorWindow.onCancelTextEditing = { [weak model] in
                model?.cancelTextEditing() ?? false
            }
        }

        window.contentViewController = NSHostingController(
            rootView: ScreenshotEditorView(model: model)
        )
        pinButton.isEnabled = true
    }

    private func presentImageLoadFailure(_ error: Error) {
        imageLoadErrorMessage = error.localizedDescription
        pinButton.isEnabled = false
        window?.contentViewController = NSHostingController(
            rootView: ScreenshotEditorLoadingView(
                metadata: imageMetadata,
                failureMessage: error.localizedDescription
            )
        )
    }
}
