import AppKit
@testable import CrossToolApp
import Testing

@MainActor
@Suite("Screenshot editor window presentation", .serialized)
struct ScreenshotEditorWindowControllerTests {
    @Test("Eligible bare S performs once while key repeat is only consumed")
    func eligibleBareSDecision() throws {
        let bareS = try makeKeyEvent()
        let repeatedS = try makeKeyEvent(isARepeat: true)

        #expect(ScreenshotEditorPinShortcut.isBareSKeyDown(bareS))
        #expect(ScreenshotEditorPinShortcut.isBareSKeyDown(repeatedS))
        #expect(ScreenshotEditorPinShortcut.decision(
            for: bareS,
            isKeyWindow: true,
            hasAttachedSheet: false,
            isEditingText: false
        ) == .performPin)
        #expect(ScreenshotEditorPinShortcut.decision(
            for: repeatedS,
            isKeyWindow: true,
            hasAttachedSheet: false,
            isEditingText: false
        ) == .consume)
    }

    @Test("Bare S is ignored outside an unobstructed key editor")
    func editorStateGuardsIgnoreBareS() throws {
        let bareS = try makeKeyEvent()

        #expect(ScreenshotEditorPinShortcut.decision(
            for: bareS,
            isKeyWindow: false,
            hasAttachedSheet: false,
            isEditingText: false
        ) == .ignore)
        #expect(ScreenshotEditorPinShortcut.decision(
            for: bareS,
            isKeyWindow: true,
            hasAttachedSheet: true,
            isEditingText: false
        ) == .ignore)
        #expect(ScreenshotEditorPinShortcut.decision(
            for: bareS,
            isKeyWindow: true,
            hasAttachedSheet: false,
            isEditingText: true
        ) == .ignore)
    }

    @Test("Command S and other non-bare keys remain available to AppKit")
    func modifiedAndNonSKeysAreIgnored() throws {
        let commandS = try makeKeyEvent(modifierFlags: .command)

        #expect(!ScreenshotEditorPinShortcut.isBareSKeyDown(commandS))
        #expect(ScreenshotEditorPinShortcut.decision(
            for: commandS,
            isKeyWindow: true,
            hasAttachedSheet: false,
            isEditingText: false
        ) == .ignore)

        for modifiers: NSEvent.ModifierFlags in [
            .control,
            .option,
            .shift,
            .function,
            [.command, .shift],
        ] {
            let event = try makeKeyEvent(modifierFlags: modifiers)
            #expect(!ScreenshotEditorPinShortcut.isBareSKeyDown(event))
            #expect(ScreenshotEditorPinShortcut.decision(
                for: event,
                isKeyWindow: true,
                hasAttachedSheet: false,
                isEditingText: false
            ) == .ignore)
        }

        let keyUpS = try makeKeyEvent(type: .keyUp)
        let bareA = try makeKeyEvent(characters: "a", keyCode: 0)
        for event in [keyUpS, bareA] {
            #expect(!ScreenshotEditorPinShortcut.isBareSKeyDown(event))
            #expect(ScreenshotEditorPinShortcut.decision(
                for: event,
                isKeyWindow: true,
                hasAttachedSheet: false,
                isEditingText: false
            ) == .ignore)
        }
    }

    @Test("Command C forwards to active text editing and otherwise copies the image")
    func commandCCopyRouting() throws {
        let commandC = try makeKeyEvent(
            modifierFlags: .command,
            characters: "c",
            keyCode: 8
        )
        let repeatedCommandC = try makeKeyEvent(
            modifierFlags: .command,
            characters: "c",
            keyCode: 8,
            isARepeat: true
        )

        #expect(ScreenshotEditorCopyShortcut.decision(
            for: commandC,
            isKeyWindow: true,
            hasAttachedSheet: false,
            hasSelectedText: false,
            isEditingText: false
        ) == .copyImage)
        #expect(ScreenshotEditorCopyShortcut.decision(
            for: repeatedCommandC,
            isKeyWindow: true,
            hasAttachedSheet: false,
            hasSelectedText: false,
            isEditingText: false
        ) == .consume)
        #expect(ScreenshotEditorCopyShortcut.decision(
            for: commandC,
            isKeyWindow: true,
            hasAttachedSheet: false,
            hasSelectedText: true,
            isEditingText: false
        ) == .forwardToTextResponder)
        #expect(ScreenshotEditorCopyShortcut.decision(
            for: commandC,
            isKeyWindow: true,
            hasAttachedSheet: false,
            hasSelectedText: false,
            isEditingText: true
        ) == .forwardToTextResponder)
        #expect(ScreenshotEditorCopyShortcut.decision(
            for: commandC,
            isKeyWindow: true,
            hasAttachedSheet: true,
            hasSelectedText: false,
            isEditingText: true
        ) == .ignore)
    }

    @Test("Mouse events bypass text editing Escape routing")
    func mouseEventsBypassTextEditingEscapeRouting() throws {
        for type: NSEvent.EventType in [
            .leftMouseDown,
            .leftMouseUp,
            .mouseMoved,
        ] {
            let event = try makeMouseEvent(type: type)
            #expect(ScreenshotEditorTextEditingEscapeShortcut.phase(for: event) == nil)
        }
    }

    @Test("Only bare Escape key events enter text editing Escape routing")
    func textEditingEscapeRouting() throws {
        let escapeKeyDown = try makeKeyEvent(
            characters: "\u{1B}",
            keyCode: 53
        )
        let escapeKeyUp = try makeKeyEvent(
            type: .keyUp,
            characters: "\u{1B}",
            keyCode: 53
        )
        #expect(
            ScreenshotEditorTextEditingEscapeShortcut.phase(for: escapeKeyDown)
                == .keyDown
        )
        #expect(
            ScreenshotEditorTextEditingEscapeShortcut.phase(for: escapeKeyUp)
                == .keyUp
        )

        let capsLockEscape = try makeKeyEvent(
            modifierFlags: .capsLock,
            characters: "\u{1B}",
            keyCode: 53
        )
        #expect(
            ScreenshotEditorTextEditingEscapeShortcut.phase(for: capsLockEscape)
                == .keyDown
        )

        for modifiers: NSEvent.ModifierFlags in [
            .command,
            .control,
            .option,
            .shift,
            .function,
            [.command, .shift],
        ] {
            let modifiedEscape = try makeKeyEvent(
                modifierFlags: modifiers,
                characters: "\u{1B}",
                keyCode: 53
            )
            #expect(
                ScreenshotEditorTextEditingEscapeShortcut.phase(for: modifiedEscape) == nil
            )
        }

        let bareA = try makeKeyEvent(characters: "a", keyCode: 0)
        #expect(ScreenshotEditorTextEditingEscapeShortcut.phase(for: bareA) == nil)
    }

    @Test("Only an unobstructed visible OnePaw main window is hidden")
    func mainWindowHidingPolicyMatrix() {
        #expect(shouldHideMainWindow())
        #expect(!shouldHideMainWindow(isEditorWindow: true))
        #expect(!shouldHideMainWindow(title: "编辑截图 — 一爪"))
        #expect(!shouldHideMainWindow(title: "Crosio"))
        #expect(!shouldHideMainWindow(isVisible: false))
        #expect(!shouldHideMainWindow(isMiniaturized: true))
        // Pinned panels and other non-main panels fail this boundary.
        #expect(!shouldHideMainWindow(canBecomeMain: false))
        #expect(!shouldHideMainWindow(isTitled: false))
        #expect(!shouldHideMainWindow(hasAttachedSheet: true))
    }

    @Test("Controller show requests scene dismissal after hiding an eligible main window")
    func controllerShowRequestsSceneDismissalForHiddenMainWindow() throws {
        _ = NSApplication.shared
        let sourceURL = try makeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let mainWindow = makeWindow(title: "一爪")
        let controller = try ScreenshotEditorWindowController(
            sourceURL: sourceURL,
            originalWasAutomaticallyCopied: true,
            onSharePNG: { _ in },
            onClose: {}
        )
        let editorWindow = try #require(controller.window)
        defer {
            NSApp.deactivate()
            editorWindow.delegate = nil
            editorWindow.orderOut(nil)
            mainWindow.delegate = nil
            mainWindow.orderOut(nil)
        }

        mainWindow.orderFront(nil)
        #expect(mainWindow.isVisible)

        let shouldDismissMainWindowScene = controller.show()

        #expect(shouldDismissMainWindowScene)
        #expect(editorWindow.isVisible)
        #expect(!mainWindow.isVisible)
    }

    @Test("Controller show skips scene dismissal when no eligible main window exists")
    func controllerShowWithoutMainWindowReturnsFalse() throws {
        _ = NSApplication.shared
        let sourceURL = try makeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let controller = try ScreenshotEditorWindowController(
            sourceURL: sourceURL,
            originalWasAutomaticallyCopied: true,
            onSharePNG: { _ in },
            onClose: {}
        )
        let editorWindow = try #require(controller.window)
        defer {
            NSApp.deactivate()
            editorWindow.delegate = nil
            editorWindow.orderOut(nil)
        }

        let shouldDismissMainWindowScene = controller.show()

        #expect(!shouldDismissMainWindowScene)
        #expect(editorWindow.isVisible)
    }

    @Test("Main window session commit and restore are terminal and idempotent")
    func mainWindowSessionCommitAndRestoreAreIdempotent() {
        let mainWindow = makeWindow(title: "一爪")
        let editorWindow = makeWindow(title: "编辑截图 — 一爪")
        let windows = [mainWindow, editorWindow]
        defer { closeWindows(windows) }

        mainWindow.orderFront(nil)
        #expect(mainWindow.isVisible)

        let committedSession = ScreenshotEditorMainWindowSession(
            editorWindow: editorWindow,
            applicationWindows: windows
        )
        #expect(committedSession.didHideMainWindow)
        #expect(!mainWindow.isVisible)

        committedSession.commitKeepingHidden()
        committedSession.commitKeepingHidden()
        committedSession.restore()
        #expect(!mainWindow.isVisible)

        mainWindow.orderFront(nil)
        let restoredSession = ScreenshotEditorMainWindowSession(
            editorWindow: editorWindow,
            applicationWindows: windows
        )
        #expect(restoredSession.didHideMainWindow)
        #expect(!mainWindow.isVisible)

        restoredSession.restore()
        #expect(mainWindow.isVisible)

        // A later cleanup must not resurrect a window that the user hid after
        // the failed presentation was already rolled back.
        mainWindow.orderOut(nil)
        restoredSession.restore()
        restoredSession.commitKeepingHidden()
        #expect(!mainWindow.isVisible)
    }

    @Test("Title-bar pin creates one detached image and closes the normal editor")
    func titleBarPinCreatesDetachedImage() async throws {
        let sourceURL = try makeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        var pinCount = 0
        var pinnedPixelSize: CGSize?
        var closeCount = 0
        let controller = try ScreenshotEditorWindowController(
            sourceURL: sourceURL,
            onPinImage: { image in
                pinCount += 1
                pinnedPixelSize = CGSize(width: image.width, height: image.height)
            },
            onSharePNG: { _ in },
            onClose: { closeCount += 1 }
        )
        let window = try #require(controller.window as? ScreenshotEditorWindow)
        defer {
            window.delegate = nil
            window.close()
        }
        _ = controller.show()
        await controller.waitUntilImageLoadFinishes()
        #expect(controller.isEditorReady)

        let accessory = try #require(window.titlebarAccessoryViewControllers.first)
        let button = try #require(accessory.view.subviews.compactMap { $0 as? NSButton }.first)
        let buttonCell = try #require(button.cell as? NSButtonCell)

        #expect(window.level == .normal)
        let buttonType = try #require(buttonCell.value(forKey: "buttonType") as? NSNumber)
        #expect(buttonType.intValue == NSButton.ButtonType.momentaryPushIn.rawValue)
        #expect(button.title.isEmpty)
        #expect(button.image != nil)
        #expect(button.imagePosition == .imageOnly)
        #expect(!button.refusesFirstResponder)
        #expect(button.accessibilityRole() == .button)
        #expect(button.accessibilityLabel() == "将当前截图贴到屏幕")
        #expect(button.accessibilityHelp()?.contains("S") == true)
        #expect(button.toolTip == "贴到屏幕（S）")
        #expect(window.onBareSPin != nil)

        button.performClick(nil)

        #expect(pinCount == 1)
        #expect(pinnedPixelSize == CGSize(width: 2, height: 2))
        #expect(closeCount == 1)
        #expect(window.level == .normal)
        #expect(!window.isVisible)
    }

    @Test("A failed pin keeps the normal editor window open")
    func failedPinKeepsEditorOpen() async throws {
        let sourceURL = try makeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        var pinCount = 0
        var closeCount = 0
        let controller = try ScreenshotEditorWindowController(
            sourceURL: sourceURL,
            onPinImage: { _ in
                pinCount += 1
                throw CocoaError(.fileWriteUnknown)
            },
            onSharePNG: { _ in },
            onClose: { closeCount += 1 }
        )
        let window = try #require(controller.window)
        defer {
            window.delegate = nil
            window.close()
        }
        _ = controller.show()
        await controller.waitUntilImageLoadFinishes()
        #expect(controller.isEditorReady)
        let accessory = try #require(window.titlebarAccessoryViewControllers.first)
        let button = try #require(accessory.view.subviews.compactMap { $0 as? NSButton }.first)

        button.performClick(nil)

        #expect(pinCount == 1)
        #expect(closeCount == 0)
        #expect(controller.window === window)
        #expect(window.level == .normal)
        #expect(window.isVisible)
    }

    private func makeTemporaryPNG() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crosio-window-pin-\(UUID()).png")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage())
        let bitmap = NSBitmapImageRep(cgImage: image)
        let pngData = try #require(bitmap.representation(using: .png, properties: [:]))
        try pngData.write(to: url, options: .atomic)
        return url
    }

    private func makeWindow(title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 120, y: 120, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        return window
    }

    private func shouldHideMainWindow(
        isEditorWindow: Bool = false,
        title: String = "一爪",
        isVisible: Bool = true,
        isMiniaturized: Bool = false,
        canBecomeMain: Bool = true,
        isTitled: Bool = true,
        hasAttachedSheet: Bool = false
    ) -> Bool {
        ScreenshotEditorMainWindowSession.shouldHide(
            isEditorWindow: isEditorWindow,
            title: title,
            isVisible: isVisible,
            isMiniaturized: isMiniaturized,
            canBecomeMain: canBecomeMain,
            isTitled: isTitled,
            hasAttachedSheet: hasAttachedSheet
        )
    }

    private func closeWindows(_ windows: [NSWindow]) {
        for window in windows {
            window.delegate = nil
            window.orderOut(nil)
            window.close()
        }
    }

    private func makeKeyEvent(
        type: NSEvent.EventType = .keyDown,
        modifierFlags: NSEvent.ModifierFlags = [],
        characters: String = "s",
        keyCode: UInt16 = 1,
        windowNumber: Int = 0,
        isARepeat: Bool = false
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: isARepeat,
            keyCode: keyCode
        ))
    }

    private func makeMouseEvent(type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: type == .mouseMoved ? 0 : 1,
            pressure: 0
        ))
    }
}
