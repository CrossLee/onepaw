@testable import CrossToolApp
import Testing

@Suite("Menu bar status icon")
struct MenuBarStatusIconTests {
    @Test("The cat remains the menu bar symbol in every state")
    func brandSymbolDoesNotDisappearWhenStateChanges() {
        for state in [
            MenuBarStatusState.idle,
            .sharing,
            .recording,
        ] {
            #expect(state.systemImageName == "cat.fill")
        }
    }

    @Test("Sharing and recording add distinct status badges")
    func statusBadges() {
        #expect(MenuBarStatusState.idle.badge == nil)
        #expect(MenuBarStatusState.sharing.badge == .sharing)
        #expect(MenuBarStatusState.recording.badge == .recording)
    }

    @Test("Recording takes precedence over sharing")
    func stateResolution() {
        #expect(MenuBarStatusState(isRecording: false, isServerRunning: false) == .idle)
        #expect(MenuBarStatusState(isRecording: false, isServerRunning: true) == .sharing)
        #expect(MenuBarStatusState(isRecording: true, isServerRunning: false) == .recording)
        #expect(MenuBarStatusState(isRecording: true, isServerRunning: true) == .recording)
    }

    @Test("Every status has a clear accessibility label")
    func accessibilityLabels() {
        #expect(MenuBarStatusState.idle.accessibilityLabel == "一爪")
        #expect(MenuBarStatusState.sharing.accessibilityLabel == "一爪正在共享")
        #expect(MenuBarStatusState.recording.accessibilityLabel == "一爪正在录屏")
    }
}
