import AppKit
import SwiftUI

@main
struct CrossToolApp: App {
    @NSApplicationDelegateAdaptor(OnePawApplicationDelegate.self)
    private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var mainWindowPresenter = MainWindowPresenter()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanelView()
                .environmentObject(model)
        } label: {
            MenuBarStatusLabel(
                model: model,
                recording: model.screenRecording,
                mainWindowPresenter: mainWindowPresenter
            )
        }
        .menuBarExtraStyle(.window)
    }
}

enum MenuBarStatusBadge: Equatable {
    case sharing
}

enum MenuBarStatusState: Equatable {
    case idle
    case sharing
    case recording

    init(isRecording: Bool, isServerRunning: Bool) {
        if isRecording {
            self = .recording
        } else if isServerRunning {
            self = .sharing
        } else {
            self = .idle
        }
    }

    var systemImageName: String {
        systemImageName(recordingPulseIsFilled: true)
    }

    func systemImageName(recordingPulseIsFilled: Bool) -> String {
        switch self {
        case .idle, .sharing:
            "cat.fill"
        case .recording:
            recordingPulseIsFilled ? "record.circle.fill" : "record.circle"
        }
    }

    var badge: MenuBarStatusBadge? {
        switch self {
        case .idle:
            nil
        case .sharing:
            .sharing
        case .recording:
            nil
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle:
            ApplicationBrand.displayName
        case .sharing:
            "\(ApplicationBrand.displayName)正在共享"
        case .recording:
            "\(ApplicationBrand.displayName)正在录屏"
        }
    }
}

private struct MenuBarStatusLabel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var recording: ScreenRecordingFeatureModel
    let mainWindowPresenter: MainWindowPresenter
    @State private var recordingPulseIsFilled = true

    private var state: MenuBarStatusState {
        MenuBarStatusState(
            isRecording: recording.isRecording,
            isServerRunning: model.isServerRunning
        )
    }

    var body: some View {
        MenuBarStatusGlyph(
            state: state,
            recordingPulseIsFilled: recordingPulseIsFilled
        )
            .accessibilityLabel(state.accessibilityLabel)
            .help(state.accessibilityLabel)
            .task(id: state) {
                recordingPulseIsFilled = true
                guard state == .recording else { return }

                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .milliseconds(600))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    recordingPulseIsFilled.toggle()
                }
            }
            .onAppear {
                openMainWindowIfNeeded(for: model.mainWindowOpenRequestID)
            }
            .onChange(of: model.mainWindowOpenRequestID) { _, requestID in
                openMainWindowIfNeeded(for: requestID)
            }
            .onChange(of: model.mainWindowDismissRequestID) { _, requestID in
                guard requestID > 0 else { return }
                mainWindowPresenter.dismiss()
            }
    }

    private func openMainWindowIfNeeded(for requestID: Int) {
        guard model.claimMainWindowOpenRequest(requestID) else { return }
        mainWindowPresenter.present(model: model)
    }
}

private struct MenuBarStatusGlyph: View {
    let state: MenuBarStatusState
    let recordingPulseIsFilled: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(
                systemName: state.systemImageName(
                    recordingPulseIsFilled: recordingPulseIsFilled
                )
            )
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .frame(width: 17, height: 17)

            if let badge = state.badge {
                MenuBarStatusBadgeGlyph(badge: badge)
                    .frame(width: 5, height: 5)
                    .offset(x: 0.75, y: -0.25)
            }
        }
        .frame(width: 19, height: 18)
    }
}

private struct MenuBarStatusBadgeGlyph: View {
    let badge: MenuBarStatusBadge

    @ViewBuilder
    var body: some View {
        switch badge {
        case .sharing:
            Circle()
                .fill(Color.green)
        }
    }
}

@MainActor
final class OnePawMainWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        guard attachedSheet == nil else {
            super.cancelOperation(sender)
            return
        }

        // Escape arrives here only after the focused control has declined to
        // consume it. Closing this retained window leaves the menu-bar app,
        // sharing server, recordings, and pinned screenshots running.
        close()
    }
}

@MainActor
final class MainWindowPresenter: ObservableObject {
    private var windowController: NSWindowController?

    func present(model: AppModel) {
        let controller: NSWindowController
        if let windowController {
            controller = windowController
        } else {
            controller = makeWindowController(model: model)
            windowController = controller
        }

        NSApp.activate(ignoringOtherApps: true)
        controller.window?.deminiaturize(nil)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        windowController?.close()
    }

    private func makeWindowController(model: AppModel) -> NSWindowController {
        let rootView = MainWindowView()
            .environmentObject(model)
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )
            ) { _ in
                model.refreshScreenCapturePermission()
            }
        let hostingController = NSHostingController(rootView: rootView)
        let window = OnePawMainWindow(contentViewController: hostingController)
        window.title = ApplicationBrand.displayName
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1_180, height: 780))
        window.contentMinSize = NSSize(width: 1_000, height: 620)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.center()
        return NSWindowController(window: window)
    }
}
