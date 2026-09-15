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

@Test func restartRestoresFilesTextMetadataAndHiddenState() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let source = root.appendingPathComponent("teacher-notes.txt")
    try Data("teacher file".utf8).write(to: source)

    let (outgoingFile, outgoingText, incomingFile, incomingText) = try withStore(
        inboxDirectory: inbox
    ) { firstStore in
        let outgoingFile = try firstStore.addSharedFile(at: source)
        let outgoingText = try firstStore.addSharedText("老师分享的文字")
        let incomingFile = try firstStore.receiveFile(
            data: Data("student file".utf8),
            filename: "student-answer.txt",
            remoteAddress: "192.168.1.20"
        )
        let incomingText = try firstStore.receiveText(
            "学生提交的文字",
            remoteAddress: "192.168.1.21"
        )
        #expect(firstStore.hideIncomingFromPublic(id: incomingFile.id))
        return (outgoingFile, outgoingText, incomingFile, incomingText)
    }

    // Opening a second store immediately also verifies that each mutating API
    // has durably written its state before returning.
    let restored = try SharedContentStore(inboxDirectory: inbox)

    #expect(restored.outgoingSnapshot() == [outgoingText, outgoingFile])
    #expect(restored.incomingSnapshot() == [incomingText, incomingFile])
    #expect(restored.publicItem(id: outgoingFile.id) == outgoingFile)
    #expect(restored.publicItem(id: outgoingText.id) == outgoingText)
    #expect(restored.publicItem(id: incomingFile.id) == nil)
    #expect(restored.publicItem(id: incomingText.id) == incomingText)
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(FileManager.default.fileExists(atPath: try #require(incomingFile.fileURL).path))
}

@Test func existingInboxFilesAreBackfilledOnceAndPrivateEntriesAreIgnored() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

    let document = inbox.appendingPathComponent("周六作业.docx")
    let image = inbox.appendingPathComponent("课堂图片.png")
    let hidden = inbox.appendingPathComponent(".DS_Store")
    let nestedDirectory = inbox.appendingPathComponent("不应扫描的文件夹", isDirectory: true)
    let nestedFile = nestedDirectory.appendingPathComponent("nested.txt")
    let symlink = inbox.appendingPathComponent("outside-link")
    let outside = root.appendingPathComponent("outside.txt")
    try Data("document".utf8).write(to: document)
    try Data("image".utf8).write(to: image)
    try Data("hidden".utf8).write(to: hidden)
    try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
    try Data("nested".utf8).write(to: nestedFile)
    try Data("outside".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
    let historicalDate = Date(timeIntervalSince1970: 1_778_229_600)
    try FileManager.default.setAttributes(
        [.creationDate: historicalDate, .modificationDate: historicalDate],
        ofItemAtPath: document.path
    )

    let firstItems = try withStore(inboxDirectory: inbox) { firstStore in
        firstStore.incomingSnapshot()
    }
    #expect(Set(firstItems.map(\.title)) == Set(["周六作业.docx", "课堂图片.png"]))
    #expect(Set(firstItems.map(\.id)).isSubset(of: Set(
        try withStore(inboxDirectory: inbox) { $0.publicSnapshot().map(\.id) }
    )))
    #expect(firstItems.first(where: { $0.title == "课堂图片.png" })?.kind == .image)
    #expect(firstItems.first(where: { $0.title == "周六作业.docx" })?.byteCount == 8)
    #expect(firstItems.first(where: { $0.title == "周六作业.docx" })?.createdAt == historicalDate)
    #expect(try Data(contentsOf: document) == Data("document".utf8))
    let stateURL = root.appendingPathComponent(SharedContentStore.persistedStateFilename)
    #expect(FileManager.default.fileExists(atPath: stateURL.path))
    let statePermissions = try FileManager.default.attributesOfItem(atPath: stateURL.path)[.posixPermissions] as? NSNumber
    #expect(statePermissions?.intValue == 0o600)

    let firstIDs = Dictionary(uniqueKeysWithValues: firstItems.map { ($0.title, $0.id) })
    let secondStore = try SharedContentStore(inboxDirectory: inbox)
    let secondItems = secondStore.incomingSnapshot()
    #expect(secondItems.count == 2)
    #expect(Dictionary(uniqueKeysWithValues: secondItems.map { ($0.title, $0.id) }) == firstIDs)
}

@Test func clearStateStaysClearedAcrossRestartWithoutDeletingPreservedFiles() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let source = root.appendingPathComponent("teacher.txt")
    try Data("teacher".utf8).write(to: source)

    let receivedFile = try withStore(inboxDirectory: inbox) { firstStore in
        _ = try firstStore.addSharedFile(at: source)
        _ = try firstStore.addSharedText("老师文字")
        let receivedFile = try firstStore.receiveFile(
            data: Data("student".utf8),
            filename: "student.txt",
            remoteAddress: nil
        )
        _ = try firstStore.receiveText("学生文字", remoteAddress: nil)
        #expect(firstStore.clearPublicItems())
        return receivedFile
    }

    try withStore(inboxDirectory: inbox) { afterPublicClear in
        #expect(afterPublicClear.publicSnapshot().isEmpty)
        #expect(afterPublicClear.outgoingSnapshot().isEmpty)
        #expect(afterPublicClear.incomingSnapshot().count == 2)
        #expect(afterPublicClear.clearIncoming(deleteFiles: false))
    }
    let afterInboxClear = try SharedContentStore(inboxDirectory: inbox)
    #expect(afterInboxClear.incomingSnapshot().isEmpty)
    #expect(afterInboxClear.publicSnapshot().isEmpty)
    #expect(FileManager.default.fileExists(atPath: try #require(receivedFile.fileURL).path))
    #expect(FileManager.default.fileExists(atPath: source.path))
}

@Test func replacingAClearedInboxFileMakesItDiscoverableAgain() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let fileURL = try withStore(inboxDirectory: inbox) { store in
        let item = try store.receiveFile(
            data: Data("old".utf8),
            filename: "answer.txt",
            remoteAddress: nil
        )
        return try #require(item.fileURL)
    }
    let originalDate = Date(timeIntervalSince1970: 1_778_229_600)
    try FileManager.default.setAttributes(
        [.modificationDate: originalDate],
        ofItemAtPath: fileURL.path
    )
    try withStore(inboxDirectory: inbox) { store in
        #expect(store.clearIncoming(deleteFiles: false))
    }
    let emptyAfterClear = try withStore(inboxDirectory: inbox) { $0.incomingSnapshot() }
    #expect(emptyAfterClear.isEmpty)

    try Data("new and different".utf8).write(to: fileURL, options: .atomic)
    try FileManager.default.setAttributes(
        [.modificationDate: originalDate.addingTimeInterval(60)],
        ofItemAtPath: fileURL.path
    )
    let restored = try SharedContentStore(inboxDirectory: inbox)
    #expect(restored.incomingSnapshot().map(\.title) == ["answer.txt"])
    #expect(try Data(contentsOf: fileURL) == Data("new and different".utf8))
}

@Test func removingAnExplicitInboxShareDoesNotReclassifyItAfterRestart() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let fileURL = try withStore(inboxDirectory: inbox) { store in
        let received = try store.receiveFile(
            data: Data("student".utf8),
            filename: "student.txt",
            remoteAddress: nil
        )
        let fileURL = try #require(received.fileURL)
        #expect(store.clearIncoming(deleteFiles: false))
        let outgoing = try store.addSharedFile(at: fileURL)
        #expect(store.removeOutgoing(id: outgoing.id))
        return fileURL
    }

    let restored = try SharedContentStore(inboxDirectory: inbox)
    #expect(restored.outgoingSnapshot().isEmpty)
    #expect(restored.incomingSnapshot().isEmpty)
    #expect(restored.publicSnapshot().isEmpty)
    #expect(FileManager.default.fileExists(atPath: fileURL.path))
}

@Test func corruptStateFailsSoftPreservesABackupAndRecoversInboxFiles() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let received = inbox.appendingPathComponent("recover-me.txt")
    try Data("safe".utf8).write(to: received)
    let stateURL = root.appendingPathComponent(SharedContentStore.persistedStateFilename)
    try Data("{ definitely not valid JSON".utf8).write(to: stateURL)

    let store = try SharedContentStore(inboxDirectory: inbox)

    #expect(store.incomingSnapshot().map(\.title) == ["recover-me.txt"])
    #expect(store.publicSnapshot().isEmpty)
    #expect(try Data(contentsOf: received) == Data("safe".utf8))
    let stateObject = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL))
    #expect(stateObject is [String: Any])
    let backups = try FileManager.default.contentsOfDirectory(atPath: root.path)
        .filter { $0.hasPrefix("SharedContent-v1.corrupt-") && $0.hasSuffix(".json") }
    #expect(backups.count == 1)
    let backupPermissions = try FileManager.default.attributesOfItem(
        atPath: root.appendingPathComponent(try #require(backups.first)).path
    )[.posixPermissions] as? NSNumber
    #expect(backupPermissions?.intValue == 0o600)
}

@Test func symbolicLinkStateIsNeverFollowedAndInboxRecoveryIsPrivate() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try Data("local answer".utf8).write(to: inbox.appendingPathComponent("answer.txt"))
    let outside = root.appendingPathComponent("outside-secret.json")
    let outsideData = Data("do not read or overwrite".utf8)
    try outsideData.write(to: outside)
    let stateURL = root.appendingPathComponent(SharedContentStore.persistedStateFilename)
    try FileManager.default.createSymbolicLink(at: stateURL, withDestinationURL: outside)

    let store = try SharedContentStore(inboxDirectory: inbox)

    #expect(store.incomingSnapshot().map(\.title) == ["answer.txt"])
    #expect(store.publicSnapshot().isEmpty)
    #expect(try Data(contentsOf: outside) == outsideData)
    let stateValues = try stateURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    #expect(stateValues.isRegularFile == true)
    #expect(stateValues.isSymbolicLink != true)
}

@Test func restoredFileMetadataIsRebuiltInsteadOfTrustedFromJSON() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let image = root.appendingPathComponent("actual-name.png")
    try Data("image bytes".utf8).write(to: image)
    let original = try withStore(inboxDirectory: inbox) { store in
        try store.addSharedFile(at: image)
    }
    let stateURL = root.appendingPathComponent(SharedContentStore.persistedStateFilename)
    var state = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
    )
    var outgoing = try #require(state["outgoingItems"] as? [[String: Any]])
    outgoing[0]["title"] = "forged-name.txt"
    outgoing[0]["mimeType"] = "text/plain\r\nX-Injected: yes"
    outgoing[0]["kind"] = "file"
    outgoing[0]["byteCount"] = 999_999
    state["outgoingItems"] = outgoing
    try JSONSerialization.data(withJSONObject: state).write(to: stateURL, options: .atomic)

    let restored = try SharedContentStore(inboxDirectory: inbox)
    let item = try #require(restored.outgoingSnapshot().first)
    #expect(item.id == original.id)
    #expect(item.title == "actual-name.png")
    #expect(item.mimeType == "image/png")
    #expect(item.kind == .image)
    #expect(item.byteCount == 11)
}

@Test func temporarilyMissingOutgoingFileCanReturnOnALaterLaunch() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let externalFile = root.appendingPathComponent("external-drive-file.txt")
    try Data("available".utf8).write(to: externalFile)
    let original = try withStore(inboxDirectory: inbox) { firstStore in
        try firstStore.addSharedFile(at: externalFile)
    }

    try FileManager.default.removeItem(at: externalFile)
    try withStore(inboxDirectory: inbox) { whileMissing in
        #expect(whileMissing.outgoingSnapshot().isEmpty)
        #expect(whileMissing.publicSnapshot().isEmpty)
    }

    try Data("available again".utf8).write(to: externalFile)
    let afterReturn = try SharedContentStore(inboxDirectory: inbox)
    #expect(afterReturn.outgoingSnapshot().map(\.id) == [original.id])
    #expect(afterReturn.publicSnapshot().map(\.id) == [original.id])
}

@Test func temporarilyMissingHiddenIncomingFileStaysHiddenWhenItReturns() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let parkedFile = root.appendingPathComponent("parked-answer.txt")
    let original = try withStore(inboxDirectory: inbox) { store in
        let item = try store.receiveFile(
            data: Data("student answer".utf8),
            filename: "answer.txt",
            remoteAddress: nil
        )
        #expect(store.hideIncomingFromPublic(id: item.id))
        return item
    }
    let inboxFile = try #require(original.fileURL)
    try FileManager.default.moveItem(at: inboxFile, to: parkedFile)

    try withStore(inboxDirectory: inbox) { whileMissing in
        #expect(whileMissing.incomingSnapshot().isEmpty)
        #expect(whileMissing.publicSnapshot().isEmpty)
    }

    try FileManager.default.moveItem(at: parkedFile, to: inboxFile)
    let restored = try SharedContentStore(inboxDirectory: inbox)
    #expect(restored.incomingSnapshot().map(\.id) == [original.id])
    #expect(restored.publicItem(id: original.id) == nil)
}

@Test func renamedHiddenIncomingFileIsRecoveredPrivately() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let original = try withStore(inboxDirectory: inbox) { store in
        let item = try store.receiveFile(
            data: Data("student answer".utf8),
            filename: "answer.txt",
            remoteAddress: nil
        )
        #expect(store.hideIncomingFromPublic(id: item.id))
        return item
    }
    let originalURL = try #require(original.fileURL)
    let renamedURL = inbox.appendingPathComponent("renamed-answer.txt")
    try FileManager.default.moveItem(at: originalURL, to: renamedURL)

    let recovered = try SharedContentStore(inboxDirectory: inbox)
    let renamedItem = try #require(recovered.incomingSnapshot().first)
    #expect(recovered.incomingSnapshot().map(\.title) == ["renamed-answer.txt"])
    #expect(renamedItem.id != original.id)
    #expect(recovered.publicSnapshot().isEmpty)
    #expect(recovered.publishIncoming(id: renamedItem.id))
    #expect(recovered.publicSnapshot().map(\.id) == [renamedItem.id])
}

@Test func clearingWhileAnInboxFileIsMissingNeverRepublishesIt() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let parkedFile = root.appendingPathComponent("parked.txt")
    let missingURL = try withStore(inboxDirectory: inbox) { store in
        let missing = try store.receiveFile(
            data: Data("temporarily away".utf8),
            filename: "missing.txt",
            remoteAddress: nil
        )
        _ = try store.receiveFile(
            data: Data("still here".utf8),
            filename: "visible.txt",
            remoteAddress: nil
        )
        let missingURL = try #require(missing.fileURL)
        try FileManager.default.moveItem(at: missingURL, to: parkedFile)
        #expect(store.clearIncoming(deleteFiles: false))
        return missingURL
    }

    try FileManager.default.moveItem(at: parkedFile, to: missingURL)
    try withStore(inboxDirectory: inbox) { restored in
        #expect(restored.incomingSnapshot().isEmpty)
        #expect(restored.publicSnapshot().isEmpty)
        _ = try restored.addSharedFile(at: missingURL)
        #expect(restored.publicSnapshot().map(\.title) == ["missing.txt"])
    }
}

@Test func deletingStateAfterMigrationRecoversInboxPrivately() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let original = try withStore(inboxDirectory: inbox) { store in
        try store.receiveFile(
            data: Data("private after deletion".utf8),
            filename: "private.txt",
            remoteAddress: nil
        )
    }
    try FileManager.default.removeItem(
        at: root.appendingPathComponent(SharedContentStore.persistedStateFilename)
    )

    let recovered = try SharedContentStore(inboxDirectory: inbox)
    let recoveredItem = try #require(recovered.incomingSnapshot().first)
    #expect(recoveredItem.title == original.title)
    #expect(recovered.publicSnapshot().isEmpty)
    #expect(recovered.publishIncoming(id: recoveredItem.id))
    #expect(recovered.publicSnapshot().map(\.id) == [recoveredItem.id])
}

@Test func sameStorageDirectoryRejectsASecondLiveStore() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    var firstStore: SharedContentStore? = try SharedContentStore(inboxDirectory: inbox)
    #expect(firstStore?.publicSnapshot().isEmpty == true)

    #expect(throws: SharedContentStoreError.storageInUse) {
        try SharedContentStore(inboxDirectory: inbox)
    }

    firstStore = nil
    let replacement = try SharedContentStore(inboxDirectory: inbox)
    #expect(replacement.publicSnapshot().isEmpty)
}

@Test func oversizedTextIsRejectedWithoutDamagingPersistedState() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    try withStore(inboxDirectory: inbox) { store in
        _ = try store.addSharedText("kept")
        #expect(throws: SharedContentStoreError.textTooLarge) {
            try store.addSharedText(String(repeating: "字", count: 70_000))
        }
    }

    let restored = try SharedContentStore(inboxDirectory: inbox)
    #expect(restored.outgoingSnapshot().map(\.detail) == ["kept"])
}

@Test func oversizedOutgoingFileIsRejectedBeforeItEntersTheShareList() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let oversized = root.appendingPathComponent("oversized.bin")
    #expect(FileManager.default.createFile(atPath: oversized.path, contents: Data()))
    let handle = try FileHandle(forWritingTo: oversized)
    try handle.truncate(atOffset: UInt64(SharedContentStore.maximumUploadBytes) + 1)
    try handle.close()
    let store = try SharedContentStore(inboxDirectory: inbox)

    #expect(throws: SharedContentStoreError.fileTooLarge) {
        try store.addSharedFile(at: oversized)
    }
    #expect(store.publicSnapshot().isEmpty)
}

@Test func deletingIncomingFilesPersistsAnEmptyState() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
    let item = try withStore(inboxDirectory: inbox) { store in
        let item = try store.receiveFile(
            data: Data("delete me".utf8),
            filename: "delete-me.txt",
            remoteAddress: nil
        )
        #expect(store.clearIncoming(deleteFiles: true))
        return item
    }

    #expect(!FileManager.default.fileExists(atPath: try #require(item.fileURL).path))
    let restoredItems = try withStore(inboxDirectory: inbox) { $0.incomingSnapshot() }
    #expect(restoredItems.isEmpty)
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
    let inbox = root.appendingPathComponent("Inbox")
    var store: SharedContentStore? = try SharedContentStore(inboxDirectory: inbox)

    let items = try await withThrowingTaskGroup(of: SharedItem.self) { group in
        for index in 0..<12 {
            let activeStore = try #require(store)
            group.addTask {
                try activeStore.receiveFile(
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
    store = nil
    let restored = try SharedContentStore(inboxDirectory: inbox)
    #expect(restored.incomingSnapshot().count == 12)
    #expect(Set(restored.incomingSnapshot().map(\.id)) == Set(items.map(\.id)))
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("crosstool-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func withStore<T>(
    inboxDirectory: URL,
    _ body: (SharedContentStore) throws -> T
) throws -> T {
    var store: SharedContentStore? = try SharedContentStore(inboxDirectory: inboxDirectory)
    defer { store = nil }
    return try body(try #require(store))
}
