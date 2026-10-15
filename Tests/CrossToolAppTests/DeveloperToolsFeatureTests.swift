import AppKit
import CrossToolCore
import Foundation
import Testing
@testable import CrossToolApp

@MainActor
@Suite("Developer tools feature", .serialized)
struct DeveloperToolsFeatureTests {
    @Test("Developer tools is one discoverable destination with three ordered tools")
    func destinationAndToolMetadata() {
        #expect(SidebarDestination.developerTools.title == "开发工具")
        #expect(
            SidebarDestination.developerTools.systemImage
                == "chevron.left.forwardslash.chevron.right"
        )
        #expect(DeveloperToolKind.allCases.map(\.title) == [
            "JSON 格式化",
            "Base64 编码",
            "UUID 生成"
        ])
    }

    @Test("Base64 input is encoded exactly and explicit copy writes the result")
    func base64EncodingAndCopy() {
        let pasteboard = makePasteboard()
        let model = DeveloperToolsFeatureModel(pasteboard: pasteboard)

        model.updateBase64Input("一爪🐾")
        model.encodeBase64()

        #expect(model.base64Output == "5LiA54iq8J+Qvg==")
        #expect(model.feedback?.kind == .success)

        model.copyBase64Result()
        #expect(pasteboard.string(forType: .string) == "5LiA54iq8J+Qvg==")
    }

    @Test("Paste is explicit and changing JSON input clears an old result")
    func jsonPasteAndFormatting() async throws {
        let pasteboard = makePasteboard()
        #expect(pasteboard.setString("{\"b\":2,\"a\":1}", forType: .string))
        let model = DeveloperToolsFeatureModel(pasteboard: pasteboard)

        model.pasteJSON()
        #expect(model.jsonInput == "{\"b\":2,\"a\":1}")

        model.formatJSON()
        try await waitUntil { !model.isFormattingJSON }
        #expect(model.jsonOutput == "{\n  \"b\": 2,\n  \"a\": 1\n}")

        model.updateJSONInput("[]")
        #expect(model.jsonOutput.isEmpty)
    }

    @Test("Clipboard JSON shortcut selects the tool and formats immediately")
    func clipboardJSONShortcutFormatsImmediately() async throws {
        let pasteboard = makePasteboard()
        #expect(pasteboard.setString("{\"ready\":true,\"count\":2}", forType: .string))
        let originalChangeCount = pasteboard.changeCount
        let model = DeveloperToolsFeatureModel(pasteboard: pasteboard)
        model.selectedTool = .base64Encoder

        model.formatJSONFromPasteboard()

        #expect(model.selectedTool == .jsonFormatter)
        #expect(model.jsonInput == "{\"ready\":true,\"count\":2}")
        try await waitUntil { !model.isFormattingJSON }
        #expect(model.jsonOutput == "{\n  \"ready\": true,\n  \"count\": 2\n}")
        #expect(model.feedback?.kind == .success)
        #expect(pasteboard.string(forType: .string) == "{\"ready\":true,\"count\":2}")
        #expect(pasteboard.changeCount == originalChangeCount)
    }

    @Test("Clipboard JSON shortcut reports invalid JSON without another click")
    func clipboardJSONShortcutReportsInvalidJSON() async throws {
        let pasteboard = makePasteboard()
        #expect(pasteboard.setString("{\"broken\":}", forType: .string))
        let model = DeveloperToolsFeatureModel(pasteboard: pasteboard)

        model.formatJSONFromPasteboard()

        try await waitUntil { !model.isFormattingJSON }
        #expect(model.jsonInput == "{\"broken\":}")
        #expect(model.jsonOutput.isEmpty)
        #expect(model.feedback?.kind == .error)
    }

    @Test("Empty clipboard shortcut clears stale JSON instead of formatting it")
    func emptyClipboardShortcutClearsStaleJSON() async throws {
        let pasteboard = makePasteboard()
        let model = DeveloperToolsFeatureModel(pasteboard: pasteboard)
        model.updateJSONInput(
            "[" + Array(repeating: "{\"value\":1}", count: 10_000)
                .joined(separator: ",") + "]"
        )
        model.formatJSON()
        pasteboard.clearContents()

        model.formatJSONFromPasteboard()
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(model.selectedTool == .jsonFormatter)
        #expect(model.jsonInput.isEmpty)
        #expect(model.jsonOutput.isEmpty)
        #expect(!model.isFormattingJSON)
        #expect(model.feedback == DeveloperToolsFeedback(
            kind: .information,
            message: "剪贴板里没有可用的文字。"
        ))
    }

    @Test("Leaving JSON cancels its pending result and feedback")
    func switchingToolsCancelsJSONFormatting() async throws {
        let model = DeveloperToolsFeatureModel(pasteboard: makePasteboard())
        model.updateJSONInput(
            "[" + Array(repeating: "{\"value\":1}", count: 10_000)
                .joined(separator: ",") + "]"
        )

        model.formatJSON()
        model.selectedTool = .base64Encoder
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(!model.isFormattingJSON)
        #expect(model.jsonOutput.isEmpty)
        #expect(model.feedback == nil)
    }

    @Test("UUID generation applies count and selected presentation")
    func uuidGenerationOptions() {
        let model = DeveloperToolsFeatureModel(pasteboard: makePasteboard())
        model.uuidCount = 3
        model.uuidFormat = .uppercase

        model.generateUUIDs()

        let lines = model.uuidOutput.split(separator: "\n")
        #expect(lines.count == 3)
        for line in lines {
            #expect(line.count == 36)
            #expect(line.filter { $0 == "-" }.count == 4)
            #expect(String(line) == line.uppercased())
            #expect(UUID(uuidString: String(line)) != nil)
        }

        model.uuidCount = 4
        #expect(model.uuidOutput.isEmpty)

        model.generateUUIDs()
        #expect(model.uuidOutput.split(separator: "\n").count == 4)
        model.uuidFormat = .lowercase
        #expect(model.uuidOutput.isEmpty)
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("onepaw.developer-tools-tests.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        return pasteboard
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds - start >= timeoutNanoseconds {
                Issue.record("Timed out waiting for developer-tool work")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
