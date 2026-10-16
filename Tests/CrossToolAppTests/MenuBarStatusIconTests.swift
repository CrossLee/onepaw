@testable import CrossToolApp
import Testing

@Suite("Menu bar status icon")
struct MenuBarStatusIconTests {
    @Test("Recording replaces the cat with a low-frequency recording pulse")
    func recordingUsesDistinctPulseFrames() {
        #expect(MenuBarStatusState.idle.systemImageName == "cat.fill")
        #expect(MenuBarStatusState.sharing.systemImageName == "cat.fill")
        #expect(MenuBarStatusState.recording.systemImageName == "record.circle.fill")
        #expect(
            MenuBarStatusState.recording.systemImageName(
                recordingPulseIsFilled: false
            ) == "record.circle"
        )
        #expect(
            MenuBarStatusState.idle.systemImageName(
                recordingPulseIsFilled: false
            ) == "cat.fill"
        )
    }

    @Test("Only sharing needs a badge because recording owns the main glyph")
    func statusBadges() {
        #expect(MenuBarStatusState.idle.badge == nil)
        #expect(MenuBarStatusState.sharing.badge == .sharing)
        #expect(MenuBarStatusState.recording.badge == nil)
    }

    @Test("Recording takes precedence over sharing")
    func stateResolution() {
        #expect(MenuBarStatusState(isRecording: false, isServerRunning: false) == .idle)
        #expect(MenuBarStatusState(isRecording: false, isServerRunning: true) == .sharing)
        #expect(MenuBarStatusState(isRecording: true, isServerRunning: false) == .recording)
        #expect(MenuBarStatusState(isRecording: true, isServerRunning: true) == .recording)
        #expect(
            MenuBarStatusState(isRecording: false, isServerRunning: false).systemImageName
                == "cat.fill"
        )
    }

    @Test("Every status has a clear accessibility label")
    func accessibilityLabels() {
        #expect(MenuBarStatusState.idle.accessibilityLabel == "一爪")
        #expect(MenuBarStatusState.sharing.accessibilityLabel == "一爪正在共享")
        #expect(MenuBarStatusState.recording.accessibilityLabel == "一爪正在录屏")
    }
}
