@testable import CrossToolApp
import Foundation
import Testing

@Suite("Menu bar panel layout")
struct MenuBarPanelLayoutTests {
    @Test("Sharing toggle immediately follows copy link and leaves the footer")
    func actionPlacementContract() {
        #expect(MenuBarPanelLayout.statusActions == [
            .copyShareLink,
            .toggleServer,
        ])
        #expect(MenuBarPanelLayout.footerActions == [
            .openMainWindow,
            .terminate,
        ])
        #expect(MenuBarPanelLayout.footerActions.contains(.toggleServer) == false)
    }

    @Test("Active recording controls stay at the top of the menu panel")
    func recordingControlPlacement() {
        for state in [
            ScreenRecordingFeatureState.choosingSource,
            .starting,
            .recording,
            .stopping,
        ] {
            #expect(MenuBarPanelLayout.recordingControlPlacement(for: state) == .top)
        }

        let completedURL = URL(fileURLWithPath: "/tmp/recording.mov")
        for state in [
            ScreenRecordingFeatureState.idle,
            .completed(completedURL),
            .cancelled,
            .failed("failed"),
        ] {
            #expect(MenuBarPanelLayout.recordingControlPlacement(for: state) == .tools)
        }
    }

    @Test("Dedicated stop shortcut takes precedence over source toggle shortcut")
    func stopShortcutPriority() {
        #expect(
            MenuBarPanelLayout.stopRecordingShortcutHint(
                dedicatedShortcut: "Ctrl+Option+S",
                activeSourceShortcut: "Ctrl+Option+R"
            ) == "快捷键 Ctrl+Option+S"
        )
        #expect(
            MenuBarPanelLayout.stopRecordingShortcutHint(
                dedicatedShortcut: nil,
                activeSourceShortcut: "Ctrl+Option+R"
            ) == "再次按 Ctrl+Option+R 停止"
        )
        #expect(
            MenuBarPanelLayout.stopRecordingShortcutHint(
                dedicatedShortcut: nil,
                activeSourceShortcut: nil
            ) == nil
        )
    }
}
