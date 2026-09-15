import AppKit
import Foundation
@testable import CrossToolApp
import Testing

@Suite("Application bundle configuration")
struct ApplicationBundleConfigurationTests {
    @Test("Chinese display branding preserves the installed application identity")
    func sourceInfoPlistUsesOnePawBrandWithoutResettingIdentity() throws {
        let info = try sourceInfoPlist()
        #expect(ApplicationBrand.displayName == "一爪")
        #expect(info["CFBundleName"] as? String == ApplicationBrand.displayName)
        #expect(info["CFBundleDisplayName"] as? String == ApplicationBrand.displayName)
        #expect(info["CFBundleIdentifier"] as? String == "com.cross.crosstool")
        #expect(info["CFBundleExecutable"] as? String == "CrossToolApp")
        for key in ["NSLocalNetworkUsageDescription", "NSScreenCaptureUsageDescription"] {
            let description = try #require(info[key] as? String)
            #expect(description.contains("一爪"))
            #expect(!description.contains("Crosio"))
        }
    }

    @Test("The browser sharing page uses the Chinese product name")
    func sharingWebPageUsesOnePawBrand() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let html = try String(contentsOf: root.appendingPathComponent(
            "Sources/CrossToolApp/Resources/Web/index.html"
        ), encoding: .utf8)
        #expect(html.contains("<title>一爪 · 课堂共享区</title>"))
        #expect(html.contains("由一爪提供") || html.contains("由 一爪 提供"))
        #expect(html.contains("链接带有共享访问码"))
        #expect(!html.contains("临时访问码"))
        #expect(!html.contains("Crosio"))

        let script = try String(contentsOf: root.appendingPathComponent(
            "Sources/CrossToolApp/Resources/Web/app.js"
        ), encoding: .utf8)
        #expect(script.contains("if (initial || linkExpired)"))
        #expect(script.contains("function expireLink()"))
        #expect(script.components(separatedBy: "expireLink();").count == 4)
        #expect(script.contains("if (state.linkExpired) return"))
        #expect(script.contains("state.linkExpired = true"))
        #expect(script.contains("elements.refreshButton.disabled = !state.interactionEnabled"))
        #expect(script.contains("等待新的共享链接"))
    }

    @Test("The approved OnePaw artwork is packaged as a multi-resolution application icon")
    func sourceAppIconContainsDesktopAndRetinaSizes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let info = try sourceInfoPlist()
        #expect(info["CFBundleIconFile"] as? String == "AppIcon.icns")
        #expect(info["CFBundleIdentifier"] as? String == "com.cross.crosstool")

        let artworkData = try Data(contentsOf: root
            .appendingPathComponent("Resources/Brand/OnePaw-AppIcon.png"))
        let artwork = try #require(NSBitmapImageRep(data: artworkData))
        #expect(artwork.pixelsWide == artwork.pixelsHigh)
        #expect(artwork.pixelsWide >= 1024)

        let icon = try #require(NSImage(contentsOf: root
            .appendingPathComponent("Resources/AppIcon.icns")))
        let sizes = Set(icon.representations.map(\.pixelsWide))
        #expect(Set([16, 32, 64, 128, 256, 512, 1024]).isSubset(of: sizes))
        #expect(icon.representations.allSatisfy { $0.pixelsWide == $0.pixelsHigh })
    }

    @Test("OnePaw is a UI-element app without becoming background-only")
    func sourceInfoPlistUsesUIElementPresentation() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoPlistURL = projectRoot
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)

        let data = try Data(contentsOf: infoPlistURL)
        let info = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )

        #expect(info["LSUIElement"] as? Bool == true)
        if let backgroundOnlyValue = info["LSBackgroundOnly"] {
            let backgroundOnly = try #require(backgroundOnlyValue as? Bool)
            #expect(backgroundOnly == false)
        }
    }

    @Test("OnePaw is an alternate Open With handler for images")
    func sourceInfoPlistRegistersImageDocuments() throws {
        let info = try sourceInfoPlist()
        let documentTypes = try #require(info["CFBundleDocumentTypes"] as? [[String: Any]])
        #expect(documentTypes.count == 1)
        let imageType = try #require(documentTypes.first)

        #expect(imageType["CFBundleTypeName"] as? String == "图片")
        #expect(imageType["CFBundleTypeRole"] as? String == "Viewer")
        #expect(imageType["LSHandlerRank"] as? String == "Alternate")
        #expect(imageType["LSItemContentTypes"] as? [String] == ["public.image"])
        #expect(imageType["NSDocumentClass"] == nil)
    }

    @MainActor
    @Test("Image open requests wait for the app model and preserve their order")
    func imageOpenRequestBrokerQueuesColdLaunchRequests() throws {
        let broker = ImageOpenRequestBroker()
        let first = URL(fileURLWithPath: "/tmp/first.png")
        let second = URL(fileURLWithPath: "/tmp/second.jpg")
        let third = URL(fileURLWithPath: "/tmp/third.heic")
        let remote = URL(string: "https://example.com/not-a-file.png")!
        var deliveries: [[URL]] = []

        broker.receive([first, remote])
        broker.receive([second])
        #expect(deliveries.isEmpty)

        broker.install { deliveries.append($0) }
        broker.receive([third])
        broker.receive([remote])

        #expect(deliveries == [[first, second], [third]])
    }

    @Test("Only a normal app launch requests the main window")
    func launchPolicyKeepsServicesAndLoginItemsInTheBackground() {
        #expect(ApplicationLaunchPolicy.shouldPresentMainWindow(isDefaultLaunch: true))
        #expect(!ApplicationLaunchPolicy.shouldPresentMainWindow(isDefaultLaunch: false))
        #expect(!ApplicationLaunchPolicy.shouldPresentMainWindow(isDefaultLaunch: nil))
    }

    @MainActor
    @Test("A cold-launch main-window request waits for the app model")
    func mainWindowBrokerQueuesAndCoalescesColdLaunchRequests() {
        let broker = MainWindowOpenRequestBroker()
        var deliveries = 0

        broker.receive()
        broker.receive()
        #expect(deliveries == 0)

        broker.install { deliveries += 1 }
        #expect(deliveries == 1)

        broker.receive()
        #expect(deliveries == 2)
    }

    @Test("Finder copy-path service accepts files and folders without replacing the selection")
    func sourceInfoPlistRegistersCopyPathService() throws {
        let info = try sourceInfoPlist()
        let services = try #require(info["NSServices"] as? [[String: Any]])
        #expect(services.count == 1)
        let service = try #require(services.first)
        let title = try #require(service["NSMenuItem"] as? [String: String])
        #expect(title["default"] == "复制路径")
        #expect(service["NSMessage"] as? String == "copyPaths")
        #expect(service["NSPortName"] as? String == info["CFBundleName"] as? String)
        #expect(service["NSSendTypes"] as? [String] == ["public.file-url", "NSFilenamesPboardType"])
        #expect(service["NSSendFileTypes"] as? [String] == ["public.item"])
        let context = try #require(service["NSRequiredContext"] as? [String: String])
        #expect(context["NSApplicationIdentifier"] == "com.apple.finder")
        #expect(service["NSReturnTypes"] == nil)
        #expect(service["NSKeyEquivalent"] == nil)
    }

    private func sourceInfoPlist() throws -> [String: Any] {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoPlistURL = projectRoot
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        let data = try Data(contentsOf: infoPlistURL)
        return try #require(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
    }
}
