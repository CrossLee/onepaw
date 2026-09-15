import Foundation
import Testing
@testable import CrossToolCore

@Test("Deleting a managed file can also remove every matching outgoing share")
func removeOutgoingFilesByURL() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let recording = root.appendingPathComponent("lesson.mov")
    try Data("recording".utf8).write(to: recording)
    let store = try SharedContentStore(inboxDirectory: inbox)
    _ = try store.addSharedFile(at: recording)
    _ = try store.addSharedFile(at: recording)

    #expect(store.outgoingSnapshot().count == 2)
    #expect(store.removeOutgoingFiles(at: recording) == 2)
    #expect(store.outgoingSnapshot().isEmpty)
    #expect(FileManager.default.fileExists(atPath: recording.path))
}

@Test func sharedContentStoreBuildsOnePublicClassroomList() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let source = root.appendingPathComponent("hello.txt")
    try Data("hello".utf8).write(to: source)

    let store = try SharedContentStore(inboxDirectory: inbox)
    let outgoingFile = try store.addSharedFile(at: source)
    let outgoingText = try store.addSharedText("共享文字")
    let incomingFile = try store.receiveFile(
        data: Data("received".utf8),
        filename: "received.txt",
        remoteAddress: "192.168.1.20"
    )

    #expect(store.outgoingSnapshot().map(\.id) == [outgoingText.id, outgoingFile.id])
    #expect(store.incomingSnapshot().map(\.id) == [incomingFile.id])
    #expect(Set(store.publicSnapshot().map(\.id)) == Set([outgoingFile.id, outgoingText.id, incomingFile.id]))
    #expect(store.publicItem(id: incomingFile.id) == incomingFile)
    #expect(incomingFile.fileURL?.deletingLastPathComponent() == inbox)
    #expect(incomingFile.remoteAddress == "192.168.1.20")

    store.hideIncomingFromPublic(id: incomingFile.id)

    #expect(!store.publicSnapshot().contains(where: { $0.id == incomingFile.id }))
    #expect(store.publicItem(id: incomingFile.id) == nil)
    #expect(store.incomingSnapshot().contains(where: { $0.id == incomingFile.id }))
    #expect(FileManager.default.fileExists(atPath: try #require(incomingFile.fileURL).path))

    let incomingText = try store.receiveText("第二位同学的答案", remoteAddress: "192.168.1.21")
    #expect(store.publicItem(id: incomingText.id) != nil)
    store.clearPublicItems()
    #expect(store.publicSnapshot().isEmpty)
    #expect(Set(store.incomingSnapshot().map(\.id)) == Set([incomingFile.id, incomingText.id]))
}

@Test func uploadedFilenameIsSanitizedAndDeduplicated() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SharedContentStore(inboxDirectory: root.appendingPathComponent("Inbox"))

    let first = try store.receiveFile(
        data: Data("one".utf8),
        filename: "../../报告.txt",
        remoteAddress: nil
    )
    let second = try store.receiveFile(
        data: Data("two".utf8),
        filename: "../../报告.txt",
        remoteAddress: nil
    )

    #expect(first.title == "报告.txt")
    #expect(second.title == "报告 2.txt")
    #expect(first.fileURL?.deletingLastPathComponent().standardizedFileURL.path == store.inboxDirectory.standardizedFileURL.path)
    #expect(second.fileURL?.deletingLastPathComponent().standardizedFileURL.path == store.inboxDirectory.standardizedFileURL.path)
    #expect(SharedContentStore.sanitizeFilename("..") == "未命名文件")
    #expect(!SharedContentStore.sanitizeFilename("bad\0name.txt").contains("\0"))
}

@Test func stagedUploadStaysPrivateUntilCommittedAndCanBeDiscarded() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SharedContentStore(inboxDirectory: root.appendingPathComponent("Inbox"))

    let stagedFile = try store.stageReceivedFile(
        data: Data("not public yet".utf8),
        filename: "draft.txt"
    )

    #expect(store.incomingSnapshot().isEmpty)
    #expect(store.publicSnapshot().isEmpty)
    #expect(FileManager.default.fileExists(atPath: stagedFile.temporaryURL.path))

    store.discardStagedFile(stagedFile)

    #expect(!FileManager.default.fileExists(atPath: stagedFile.temporaryURL.path))
    #expect(store.incomingSnapshot().isEmpty)
}

@Test func storeInitializationCleansOnlyStalePrivateStagingEntries() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let staging = inbox.appendingPathComponent(".onepaw-staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let orphanDirectory = staging.appendingPathComponent("old-session", isDirectory: true)
    let activeDirectory = staging.appendingPathComponent("active-session", isDirectory: true)
    try FileManager.default.createDirectory(at: orphanDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: activeDirectory, withIntermediateDirectories: true)
    let orphan = orphanDirectory.appendingPathComponent("orphan.upload")
    let active = activeDirectory.appendingPathComponent("active.upload")
    let userFile = inbox.appendingPathComponent("keep-me.txt")
    try Data("orphan".utf8).write(to: orphan)
    try Data("active".utf8).write(to: active)
    try Data("keep".utf8).write(to: userFile)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-25 * 60 * 60)],
        ofItemAtPath: orphanDirectory.path
    )

    let store = try SharedContentStore(inboxDirectory: inbox)

    #expect(!FileManager.default.fileExists(atPath: orphanDirectory.path))
    #expect(FileManager.default.fileExists(atPath: active.path))
    #expect(FileManager.default.fileExists(atPath: userFile.path))
    #expect(FileManager.default.fileExists(atPath: staging.path))
    withExtendedLifetime(store) {}
}

@Test func concurrentUploadsWithTheSameNameNeverOverwriteEachOther() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SharedContentStore(inboxDirectory: root.appendingPathComponent("Inbox"))

    let items = try await withThrowingTaskGroup(of: SharedItem.self) { group in
        for index in 0..<12 {
            group.addTask {
                try store.receiveFile(
                    data: Data("payload-\(index)".utf8),
                    filename: "课堂作业.txt",
                    remoteAddress: "student-\(index)"
                )
            }
        }

        var uploaded: [SharedItem] = []
        for try await item in group {
            uploaded.append(item)
        }
        return uploaded
    }

    #expect(items.count == 12)
    #expect(Set(items.map(\.title)).count == 12)
    let storedPayloads = try items.map { item in
        try Data(contentsOf: #require(item.fileURL))
    }
    let expectedPayloads = Set((0..<12).map { Data("payload-\($0)".utf8) })
    #expect(Set(storedPayloads) == expectedPayloads)
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("crosstool-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
