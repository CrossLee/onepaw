@testable import CrossToolApp
import Testing

@Suite("Screenshot shortcut latency contracts")
struct ScreenshotShortcutLatencyContractTests {
    @Test("Capture activity invalidates only the screenshot page")
    func captureActivityInvalidationIsScoped() {
        #expect(!CaptureActivityInvalidationPolicy.shouldPublish(selectedDestination: nil))

        for destination in SidebarDestination.allCases {
            #expect(
                CaptureActivityInvalidationPolicy.shouldPublish(
                    selectedDestination: destination
                ) == (destination == .screenshot),
                "Unexpected capture-state invalidation for \(destination.rawValue)"
            )
        }
    }

    @Test("Capture activity does not restart image-compression thumbnail work")
    func imageCompressionPageDoesNotObserveCaptureActivity() {
        #expect(!CaptureActivityInvalidationPolicy.shouldPublish(
            selectedDestination: .imageCompression
        ))
    }

    @Test(
        "A completed preflight is never repeated by the capture service",
        arguments: ScreenshotMode.allCases
    )
    func completedPreflightSkipsServiceCheck(mode: ScreenshotMode) {
        #expect(!ScreenshotPermissionPreflightPolicy.needsCheck(
            mode: mode,
            permissionWasPreflighted: true
        ))
    }

    @Test(
        "Only persistent-permission modes require an uncompleted preflight",
        arguments: ScreenshotMode.allCases
    )
    func uncompletedPreflightMatchesModeRequirement(mode: ScreenshotMode) {
        #expect(
            ScreenshotPermissionPreflightPolicy.needsCheck(
                mode: mode,
                permissionWasPreflighted: false
            ) == mode.requiresPersistentScreenCapturePermission
        )
    }
}
