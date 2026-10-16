import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum ScreenshotMode: String, CaseIterable, Identifiable {
    case region
    case window
    case screen
    case delayedScreen
    case framedScreen
    case multiWindow
    case scrolling

    var id: String { rawValue }

    var title: String {
        switch self {
        case .region: return "区域截图"
        case .window: return "窗口截图"
        case .screen: return "全屏截图"
        case .delayedScreen: return "延时全屏截图"
        case .framedScreen: return "带壳截图"
        case .multiWindow: return "多窗口截图"
        case .scrolling: return "长截图"
        }
    }

    var systemImage: String {
        switch self {
        case .region: return "viewfinder"
        case .window: return "macwindow"
        case .screen: return "rectangle.inset.filled"
        case .delayedScreen: return "timer"
        case .framedScreen: return "laptopcomputer"
        case .multiWindow: return "macwindow.on.rectangle"
        case .scrolling: return "rectangle.arrowtriangle.2.outward"
        }
    }

    var summary: String {
        switch self {
        case .region:
            return "拖拽选择区域，或按空格切换窗口"
        case .window:
            return "选择一个窗口并保留窗口阴影"
        case .screen:
            return "立即截取鼠标所在的屏幕"
        case .delayedScreen:
            return "倒计时 5 秒后截取鼠标所在屏幕"
        case .framedScreen:
            return "倒计时后把整屏放入一爪 Mac 外框"
        case .multiWindow:
            return "使用系统选择器选择多个窗口并合成"
        case .scrolling:
            return "框选可滚动内容，滚动过程中连续采集并拼接"
        }
    }

    /// Picker-based modes are explicitly authorized by the user's selection
    /// and can operate even when persistent Screen Recording permission has
    /// not yet been granted.
    var requiresPersistentScreenCapturePermission: Bool {
        switch self {
        case .multiWindow:
            return false
        default:
            return true
        }
    }
}

enum ScreenshotServiceError: LocalizedError {
    case cancelled
    case toolUnavailable
    case permissionDenied
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "截图已取消"
        case .toolUnavailable: return "系统截图工具不可用"
        case .permissionDenied: return "截图权限尚未生效"
        case .failed(let message): return message
        }
    }
}

enum ScreenshotPermissionPreflightPolicy {
    static func needsCheck(
        mode: ScreenshotMode,
        permissionWasPreflighted: Bool
    ) -> Bool {
        mode.requiresPersistentScreenCapturePermission && !permissionWasPreflighted
    }
}

enum ScreenCapturePermissionRequestResult {
    case contentAvailable
    case userDeclined
    case failed(String)
}

final class ScreenshotService: @unchecked Sendable {
    private let outputDirectory: URL

    init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
    }

    var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Asks ScreenCaptureKit to enumerate shareable content. On first use this
    /// is the modern macOS authorization path for screen capture.
    func requestPermission() async -> ScreenCapturePermissionRequestResult {
        guard !hasPermission else { return .contentAvailable }

        do {
            _ = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            return .contentAvailable
        } catch {
            let nsError = error as NSError
            if nsError.domain == SCStreamErrorDomain,
               nsError.code == SCStreamError.Code.userDeclined.rawValue {
                return .userDeclined
            }
            return .failed(error.localizedDescription)
        }
    }

    @MainActor
    func capture(
        _ mode: ScreenshotMode,
        permissionWasPreflighted: Bool = false
    ) async throws -> URL {
        guard !ScreenshotPermissionPreflightPolicy.needsCheck(
            mode: mode,
            permissionWasPreflighted: permissionWasPreflighted
        ) || hasPermission else {
            throw ScreenshotServiceError.permissionDenied
        }

        do {
            switch mode {
            case .region, .window, .screen:
                return try await captureWithSystemTool(mode)
            case .delayedScreen:
                return try await captureDelayedDisplay()
            case .framedScreen:
                return try await captureFramedDisplay()
            case .multiWindow:
                return try await captureMultipleWindows()
            case .scrolling:
                return try await captureScrollingRegion()
            }
        } catch ScreenCaptureKitBackendError.permissionDenied {
            throw ScreenshotServiceError.permissionDenied
        } catch ScreenCaptureKitBackendError.captureCancelled {
            throw ScreenshotServiceError.cancelled
        }
    }

    @MainActor
    private func captureDelayedDisplay() async throws -> URL {
        guard let target = displayUnderMouse() else {
            throw ScreenshotServiceError.failed("找不到鼠标所在的屏幕")
        }
        let filter = try await ScreenCaptureKitScreenshotBackend.contentFilter(
            forDisplayID: target.displayID
        )
        let countdown = ScreenshotCountdownWindowController(screen: target.screen)
        do {
            try await countdown.run(seconds: 5)
            let image = try await ScreenCaptureKitScreenshotBackend.captureImage(using: filter)
            return try writeAdvancedCapture(image, label: "延时全屏截图")
        } catch is ScreenshotCountdownError {
            throw ScreenshotServiceError.cancelled
        }
    }

    @MainActor
    private func captureFramedDisplay() async throws -> URL {
        guard let target = displayUnderMouse() else {
            throw ScreenshotServiceError.failed("找不到鼠标所在的屏幕")
        }
        let filter = try await ScreenCaptureKitScreenshotBackend.contentFilter(
            forDisplayID: target.displayID
        )
        let countdown = ScreenshotCountdownWindowController(screen: target.screen)
        do {
            try await countdown.run(seconds: 3)
            let screenImage = try await ScreenCaptureKitScreenshotBackend.captureImage(using: filter)
            let framedImage = try ScreenshotFrameRenderer.render(screenImage: screenImage)
            return try writeAdvancedCapture(framedImage, label: "带壳截图")
        } catch is ScreenshotCountdownError {
            throw ScreenshotServiceError.cancelled
        }
    }

    @MainActor
    private func captureMultipleWindows() async throws -> URL {
        do {
            let filter = try await ScreenCaptureContentPicker.shared.selectContent(.multipleWindows)
            let image = try await ScreenCaptureKitScreenshotBackend.captureImage(using: filter)
            return try writeAdvancedCapture(image, label: "多窗口截图")
        } catch ScreenCaptureKitBackendError.pickerCancelled {
            throw ScreenshotServiceError.cancelled
        }
    }

    @MainActor
    private func captureScrollingRegion() async throws -> URL {
        let hiddenWindows = TemporarilyHiddenAppWindows()
        defer { hiddenWindows.restore() }

        do {
            // Give WindowServer a moment to expose the real target content.
            // The capture filter excludes OnePaw, so the selector must not let
            // users frame an area while looking at a OnePaw window that will
            // disappear from the actual pixels.
            try await Task.sleep(for: .milliseconds(120))
            let selection = try await ScreenRegionSelectionCoordinator.shared
                .selectRegion()
            // The selector temporarily activates OnePaw. Return focus to the
            // target application before the first frame and before the user
            // starts scrolling; the session overlay itself is nonactivating.
            NSApp.deactivate()
            let coordinator = LongScreenshotCoordinator()
            var captureSession: ScreenCaptureKitScreenshotBackend.RegionCaptureSession?
            let image = try await coordinator.capture(selection: selection) {
                if let captureSession {
                    return try await captureSession.capture()
                }
                let prepared = try await ScreenCaptureKitScreenshotBackend
                    .makeRegionCaptureSession(selection)
                captureSession = prepared
                return try await prepared.capture()
            }
            return try writeAdvancedCapture(image, label: "长截图")
        } catch ScreenRegionSelectionError.cancelled {
            throw ScreenshotServiceError.cancelled
        } catch LongScreenshotCoordinatorError.cancelled {
            throw ScreenshotServiceError.cancelled
        } catch is CancellationError {
            throw ScreenshotServiceError.cancelled
        }
    }

    private func writeAdvancedCapture(_ image: CGImage, label: String) throws -> URL {
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let outputURL = makeOutputURL(label: label)
        try ScreenCaptureKitScreenshotBackend.writePNG(image, to: outputURL)
        return outputURL
    }

    @MainActor
    private func displayUnderMouse() -> (screen: NSScreen, displayID: CGDirectDisplayID)? {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(mouseLocation, $0.frame, false)
        }) ?? NSScreen.main,
        let screenNumber = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else {
            return nil
        }
        return (screen, CGDirectDisplayID(screenNumber.uint32Value))
    }

    private func makeOutputURL(label: String = "截图") -> URL {
        let uniqueSuffix = UUID().uuidString.prefix(8).lowercased()
        let filename = "\(label) \(Self.timestamp()) \(uniqueSuffix).png"
        return outputDirectory.appendingPathComponent(filename)
    }

    private func captureWithSystemTool(_ mode: ScreenshotMode) async throws -> URL {

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let executable = URL(fileURLWithPath: "/usr/sbin/screencapture")
                guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                    continuation.resume(throwing: ScreenshotServiceError.toolUnavailable)
                    return
                }

                try? FileManager.default.createDirectory(
                    at: self.outputDirectory,
                    withIntermediateDirectories: true
                )
                let outputURL = self.makeOutputURL()
                let process = Process()
                let errorPipe = Pipe()
                process.executableURL = executable
                process.standardError = errorPipe

                switch mode {
                case .region:
                    process.arguments = ["-i", "-x", outputURL.path]
                case .window:
                    process.arguments = ["-i", "-W", "-x", outputURL.path]
                case .screen:
                    process.arguments = ["-m", "-x", outputURL.path]
                case .delayedScreen, .framedScreen, .multiWindow, .scrolling:
                    continuation.resume(
                        throwing: ScreenshotServiceError.failed("不支持的系统截图模式")
                    )
                    return
                }

                do {
                    try process.run()
                    process.waitUntilExit()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorMessage = String(data: errorData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard process.terminationStatus == 0 else {
                        if mode != .screen && !FileManager.default.fileExists(atPath: outputURL.path) {
                            continuation.resume(throwing: ScreenshotServiceError.cancelled)
                        } else {
                            let detail = (errorMessage?.isEmpty == false)
                                ? errorMessage!
                                : "系统截图工具退出码 \(process.terminationStatus)"
                            continuation.resume(throwing: ScreenshotServiceError.failed(detail))
                        }
                        return
                    }
                    guard FileManager.default.fileExists(atPath: outputURL.path) else {
                        continuation.resume(throwing: ScreenshotServiceError.failed("截图文件没有生成"))
                        return
                    }
                    continuation.resume(returning: outputURL)
                } catch {
                    continuation.resume(throwing: ScreenshotServiceError.failed(error.localizedDescription))
                }
            }
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }
}

@MainActor
final class TemporarilyHiddenAppWindows {
    private var windowsToRestore: [NSWindow]
    private var pinnedWindowsToRestore: [PinnedScreenshotPanel]

    init() {
        let appWindows = NSApp.windows
        let visibleWindows = appWindows.filter(\.isVisible)
        windowsToRestore = visibleWindows.filter { window in
            (window.canBecomeMain && window.styleMask.contains(.titled))
        }
        pinnedWindowsToRestore = appWindows.compactMap { window in
            guard let panel = window as? PinnedScreenshotPanel,
                  panel.allowsVisibilityRecovery else {
                return nil
            }
            return panel
        }

        for window in visibleWindows where !(window is PinnedScreenshotPanel) {
            window.orderOut(nil)
        }
        // Include already-suppressed pins so nested capture scopes cannot let
        // an outer scope restore a pin while an inner capture is still active.
        for panel in pinnedWindowsToRestore {
            panel.beginTemporaryVisibilitySuppression()
        }
    }

    isolated deinit {
        // Every current caller restores explicitly, but keep the visibility
        // lease fail-safe: cancellation or a future early-return path must not
        // strand a pin in its temporarily suppressed state.
        restore()
    }

    /// Restores only detached screenshot pins while keeping the main OnePaw
    /// window hidden. Region recording uses this after selection so the user
    /// can keep referencing pins without exposing them to the capture filter.
    func restorePinnedScreenshotWindows() {
        let pinnedWindows = pinnedWindowsToRestore
        pinnedWindowsToRestore.removeAll()
        for panel in pinnedWindows {
            panel.endTemporaryVisibilitySuppression()
        }
    }

    func restore() {
        let windows = windowsToRestore
        windowsToRestore.removeAll()
        for window in windows {
            window.orderFront(nil)
        }
        restorePinnedScreenshotWindows()
    }
}
