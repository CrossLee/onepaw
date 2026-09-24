import Foundation
import Testing
@testable import CrossToolCore

@Suite("Clipboard history store")
struct ClipboardHistoryStoreTests {
    @Test("Records text and image data with private storage permissions")
    func recordsTextAndImage() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try ClipboardHistoryStore(directory: root)
        let textDate = Date(timeIntervalSince1970: 100)
        let imageDate = Date(timeIntervalSince1970: 200)
        let text = try await store.record(.text("Hello, 一爪"), at: textDate)
        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let image = try await store.record(
            .image(
                data: imageBytes,
                pasteboardType: "public.png",
                pixelWidth: 320,
                pixelHeight: 180,
                fileExtension: "PNG"
            ),
            at: imageDate
        )

        let snapshot = await store.snapshot()
        #expect(snapshot.map(\.id) == [image.id, text.id])
        #expect(try await store.imageData(for: image.id) == imageBytes)
        #expect(text.byteCount == Int64("Hello, 一爪".utf8.count))
        if case .image(let metadata) = image.content {
            #expect(metadata.fileExtension == "png")
            #expect(metadata.pixelWidth == 320)
            #expect(metadata.pixelHeight == 180)
            #expect(metadata.byteCount == Int64(imageBytes.count))
        } else {
            Issue.record("Expected an image history item")
        }

        #expect(permissions(at: root) == 0o700)
        #expect(permissions(at: root.appendingPathComponent("Items")) == 0o700)
        #expect(permissions(at: root.appendingPathComponent("ClipboardHistory-v1.json")) == 0o600)
        let payloads = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Items"),
            includingPropertiesForKeys: nil
        )
        #expect(payloads.count == 1)
        #expect(payloads[0].lastPathComponent == "\(image.id.uuidString.lowercased()).png")
        #expect(permissions(at: payloads[0]) == 0o600)
    }

    @Test("Duplicate content keeps its identity and moves to the front")
    func deduplicatesAndRefreshes() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ClipboardHistoryStore(directory: root)

        let first = try await store.record(.text("same"), at: Date(timeIntervalSince1970: 1))
        let other = try await store.record(.text("other"), at: Date(timeIntervalSince1970: 2))
        let refreshed = try await store.record(.text("same"), at: Date(timeIntervalSince1970: 3))

        let snapshot = await store.snapshot()
        #expect(snapshot.count == 2)
        #expect(snapshot.map(\.id) == [first.id, other.id])
        #expect(refreshed.id == first.id)
        #expect(refreshed.createdAt == Date(timeIntervalSince1970: 3))
    }

    @Test("Count is clamped and trimming removes old image payloads")
    func trimsByCount() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ClipboardHistoryStore(directory: root, maximumItemCount: 500)
        #expect(await store.maximumItemCount == 200)

        let oldImage = try await store.record(
            .image(
                data: Data([1, 2, 3]),
                pasteboardType: "public.png",
                pixelWidth: 1,
                pixelHeight: 1,
                fileExtension: "png"
            )
        )
        _ = try await store.record(.text("newer"))

        let trimmed = try await store.trim(maximumItemCount: 0)
        #expect(await store.maximumItemCount == 1)
        #expect(trimmed.count == 1)
        #expect(trimmed.first?.content == .text("newer"))
        #expect(!FileManager.default.fileExists(
            atPath: payloadURL(for: oldImage, root: root).path
        ))
    }

    @Test("Disk budget evicts oldest entries and rejects a single oversized capture")
    func enforcesDiskBudget() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ClipboardHistoryStore(
            directory: root,
            maximumItemCount: 20,
            maximumDiskBytes: 8
        )

        let oldest = try await store.record(.text("12345"))
        let newest = try await store.record(.text("6789"))
        let snapshot = await store.snapshot()
        #expect(snapshot.map(\.id) == [newest.id])
        #expect(!snapshot.contains(where: { $0.id == oldest.id }))

        await #expect(throws: ClipboardHistoryStoreError.captureExceedsDiskBudget) {
            try await store.record(.text("123456789"))
        }
    }

    @Test("A full text index evicts old entries instead of rejecting newer copies")
    func evictsOldTextWhenIndexIsFull() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ClipboardHistoryStore(directory: root, maximumItemCount: 20)
        let body = String(repeating: "x", count: 900_000)

        for index in 0 ..< 10 {
            _ = try await store.record(
                .text("entry-\(index)-\(body)"),
                at: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let snapshot = await store.snapshot()
        #expect(!snapshot.isEmpty)
        #expect(snapshot.count < 10)
        if case .text(let newest) = snapshot.first?.content {
            #expect(newest.hasPrefix("entry-9-"))
        } else {
            Issue.record("Expected the newest large text item to be retained")
        }

        let restored = try ClipboardHistoryStore(directory: root, maximumItemCount: 20)
        #expect(await restored.snapshot() == snapshot)
    }

    @Test("A single text item larger than the safe index is rejected")
    func rejectsTextLargerThanIndexBudget() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ClipboardHistoryStore(
            directory: root,
            maximumDiskBytes: 20 * 1_024 * 1_024
        )
        let oversizedText = String(repeating: "x", count: 9 * 1_024 * 1_024)

        await #expect(throws: ClipboardHistoryStoreError.captureExceedsDiskBudget) {
            try await store.record(.text(oversizedText))
        }
        #expect(await store.snapshot().isEmpty)
    }

    @Test("History persists without exposing user content in image filenames")
    func persistsAcrossInstances() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("private image bytes".utf8)

        let firstStore = try ClipboardHistoryStore(directory: root)
        let text = try await firstStore.record(.text("private lesson text"))
        let image = try await firstStore.record(
            .image(
                data: bytes,
                pasteboardType: "public.tiff",
                pixelWidth: 20,
                pixelHeight: 10,
                fileExtension: "tiff"
            )
        )

        let restoredStore = try ClipboardHistoryStore(directory: root)
        let restored = await restoredStore.snapshot()
        #expect(restored.map(\.id) == [image.id, text.id])
        #expect(try await restoredStore.imageData(for: image.id) == bytes)

        let payloadNames = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("Items").path
        )
        #expect(payloadNames == ["\(image.id.uuidString.lowercased()).tiff"])
        #expect(!payloadNames[0].contains("private"))
    }

    @Test("Symbolic-link payloads are rejected and cleaned without deleting their targets")
    func rejectsSymbolicLinkPayload() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).png")
        try Data("outside".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let seedStore = try ClipboardHistoryStore(directory: root)
        let item = try await seedStore.record(
            .image(
                data: Data("inside".utf8),
                pasteboardType: "public.png",
                pixelWidth: 1,
                pixelHeight: 1,
                fileExtension: "png"
            )
        )
        let payload = payloadURL(for: item, root: root)
        try FileManager.default.removeItem(at: payload)
        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: outside)

        let restoredStore = try ClipboardHistoryStore(directory: root)
        #expect(await restoredStore.snapshot().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: payload.path))
        #expect(try Data(contentsOf: outside) == Data("outside".utf8))
    }

    @Test("Invalid image extensions cannot traverse outside the owned directory")
    func rejectsTraversalExtension() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ClipboardHistoryStore(directory: root)

        await #expect(throws: ClipboardHistoryStoreError.invalidCapture) {
            try await store.record(
                .image(
                    data: Data([1]),
                    pasteboardType: "public.png",
                    pixelWidth: 1,
                    pixelHeight: 1,
                    fileExtension: "../png"
                )
            )
        }
        #expect(await store.snapshot().isEmpty)
    }

    @Test("Delete and clear update the index and remove image payloads")
    func deletesAndClears() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ClipboardHistoryStore(directory: root)

        let first = try await store.record(
            .image(
                data: Data([1]),
                pasteboardType: "public.png",
                pixelWidth: 1,
                pixelHeight: 1,
                fileExtension: "png"
            )
        )
        let second = try await store.record(
            .image(
                data: Data([2]),
                pasteboardType: "public.png",
                pixelWidth: 1,
                pixelHeight: 1,
                fileExtension: "png"
            )
        )

        #expect(try await store.delete(id: first.id))
        #expect(!FileManager.default.fileExists(atPath: payloadURL(for: first, root: root).path))
        let deletedUnknownItem = try await store.delete(id: UUID())
        #expect(!deletedUnknownItem)

        try await store.clear()
        #expect(await store.snapshot().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: payloadURL(for: second, root: root).path))

        let restored = try ClipboardHistoryStore(directory: root)
        #expect(await restored.snapshot().isEmpty)
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("onepaw-clipboard-history-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
}

private func permissions(at url: URL) -> Int {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private func payloadURL(for item: ClipboardHistoryItem, root: URL) -> URL {
    guard case .image(let metadata) = item.content else {
        return root.appendingPathComponent("not-an-image")
    }
    return root
        .appendingPathComponent("Items", isDirectory: true)
        .appendingPathComponent(
            "\(item.id.uuidString.lowercased()).\(metadata.fileExtension)",
            isDirectory: false
        )
}
