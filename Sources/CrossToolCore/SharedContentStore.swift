import Foundation
import Darwin

public enum SharedContentStoreError: LocalizedError, Equatable {
    case notARegularFile
    case fileTooLarge
    case emptyText
    case textTooLarge
    case itemNotFound
    case storageInUse
    case persistenceFailed

    public var errorDescription: String? {
        switch self {
        case .notARegularFile:
            return "只能分享普通文件"
        case .fileTooLarge:
            return "单个共享或上传文件不能超过 256 MB"
        case .emptyText:
            return "文字内容不能为空"
        case .textTooLarge:
            return "单条共享文字不能超过 64 KB"
        case .itemNotFound:
            return "共享内容不存在或已经移除"
        case .storageInUse:
            return "另一份一爪正在使用共享记录"
        case .persistenceFailed:
            return "无法保存共享记录，请检查磁盘空间和文件权限"
        }
    }
}

private struct PersistedSharedContentState: Codable {
    static let currentVersion = 1

    let version: Int
    let outgoingItems: [PersistedSharedItem]
    let incomingItems: [PersistedSharedItem]
    let hiddenIncomingItemIDs: Set<UUID>
    let suppressedInboxFiles: Set<PersistedInboxFileFingerprint>
}

/// Only persist identity and user-authored fields. File names, sizes, kinds,
/// and MIME types are rebuilt from the current file instead of trusting JSON.
private struct PersistedSharedItem: Codable {
    let id: UUID
    let detail: String?
    let fileURL: URL?
    let createdAt: Date
    let remoteAddress: String?

    init(_ item: SharedItem) {
        id = item.id
        detail = item.detail
        fileURL = item.fileURL
        createdAt = item.createdAt
        remoteAddress = item.remoteAddress
    }
}

private struct PersistedInboxFileFingerprint: Codable, Hashable {
    let filename: String
    let byteCount: Int64?
    let modificationDate: Date?
    let suppressedAt: Date?

    init(
        filename: String,
        byteCount: Int64?,
        modificationDate: Date?,
        suppressedAt: Date? = nil
    ) {
        self.filename = filename
        self.byteCount = byteCount
        self.modificationDate = modificationDate
        self.suppressedAt = suppressedAt
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.filename == rhs.filename
            && lhs.byteCount == rhs.byteCount
            && lhs.modificationDate == rhs.modificationDate
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(filename)
        hasher.combine(byteCount)
        hasher.combine(modificationDate)
    }

    var isWildcard: Bool {
        byteCount == nil && modificationDate == nil
    }

    func suppresses(_ current: Self) -> Bool {
        filename == current.filename && (isWildcard || self == current)
    }
}

struct StagedIncomingFile: Sendable {
    let temporaryURL: URL
    let filename: String
    let byteCount: Int64
}

public final class SharedContentStore: @unchecked Sendable {
    public static let maximumUploadBytes = 256 * 1024 * 1024
    static let persistedStateFilename = "SharedContent-v1.json"
    static let migrationMarkerFilename = ".SharedContent-v1.migrated"
    private static let staleStagingAge: TimeInterval = 24 * 60 * 60
    private static let maximumPersistedStateBytes: Int64 = 16 * 1024 * 1024
    private static let maximumPersistedItems = 10_000
    private static let maximumPersistedTextBytes = 64 * 1024
    private static let maximumPersistedStringCharacters = 2_048
    private static let maximumCorruptBackups = 3
    private static let storageRegistryLock = NSLock()
    nonisolated(unsafe) private static var claimedStorageRoots: Set<String> = []

    private let lock = NSLock()
    private let inboxIOLock = NSLock()
    private var outgoingItems: [SharedItem] = []
    private var incomingItems: [SharedItem] = []
    private var hiddenIncomingItemIDs: Set<UUID> = []
    private var suppressedInboxFiles: Set<PersistedInboxFileFingerprint> = []
    private var changeHandler: (@Sendable () -> Void)?

    public let inboxDirectory: URL
    private let stagingDirectory: URL
    private let persistedStateURL: URL
    private let migrationMarkerURL: URL
    private let storageRootPath: String
    private var storageLockDescriptor: Int32 = -1
    private var inboxDescriptor: Int32 = -1

    public init(inboxDirectory: URL) throws {
        self.inboxDirectory = inboxDirectory
        let storageRoot = inboxDirectory.deletingLastPathComponent()
        self.persistedStateURL = storageRoot
            .appendingPathComponent(Self.persistedStateFilename, isDirectory: false)
        self.migrationMarkerURL = storageRoot
            .appendingPathComponent(Self.migrationMarkerFilename, isDirectory: false)
        self.storageRootPath = storageRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let stagingRoot = inboxDirectory.appendingPathComponent(".onepaw-staging", isDirectory: true)
        self.stagingDirectory = stagingRoot.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: storageRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: storageRoot.path
        )
        try Self.claimStorageRoot(storageRootPath)
        var shouldReleaseStorageRoot = true
        defer {
            if shouldReleaseStorageRoot {
                if inboxDescriptor >= 0 {
                    close(inboxDescriptor)
                    inboxDescriptor = -1
                }
                if storageLockDescriptor >= 0 {
                    flock(storageLockDescriptor, LOCK_UN)
                    close(storageLockDescriptor)
                    storageLockDescriptor = -1
                }
                Self.releaseStorageRoot(storageRootPath)
            }
        }

        do {
            storageLockDescriptor = try Self.acquireStorageLock(in: storageRoot)
            try FileManager.default.createDirectory(
                at: inboxDirectory,
                withIntermediateDirectories: true
            )
            inboxDescriptor = open(
                inboxDirectory.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard inboxDescriptor >= 0 else {
                throw CocoaError(.fileReadUnknown)
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: inboxDirectory.path
            )
        } catch {
            if storageLockDescriptor >= 0 {
                flock(storageLockDescriptor, LOCK_UN)
                close(storageLockDescriptor)
                storageLockDescriptor = -1
            }
            throw error
        }
        try FileManager.default.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true
        )
        Self.removeStaleStagingEntries(in: stagingRoot)
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        try restorePersistedStateAndDiscoverInboxFiles()
        shouldReleaseStorageRoot = false
    }

    deinit {
        try? FileManager.default.removeItem(at: stagingDirectory)
        if inboxDescriptor >= 0 {
            close(inboxDescriptor)
        }
        if storageLockDescriptor >= 0 {
            flock(storageLockDescriptor, LOCK_UN)
            close(storageLockDescriptor)
        }
        Self.releaseStorageRoot(storageRootPath)
    }

    public func setChangeHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        changeHandler = handler
        lock.unlock()
    }

    @discardableResult
    public func addSharedFile(at url: URL) throws -> SharedItem {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SharedContentStoreError.notARegularFile
        }
        guard Int64(values.fileSize ?? 0) <= Int64(Self.maximumUploadBytes) else {
            throw SharedContentStoreError.fileTooLarge
        }

        let item = SharedItem(
            kind: MIMEType.kind(forFileAt: url),
            direction: .outgoing,
            title: url.lastPathComponent,
            fileURL: url,
            byteCount: values.fileSize.map(Int64.init),
            mimeType: MIMEType.forFile(at: url)
        )
        try mutate {
            removeInboxSuppression(for: item.fileURL)
            outgoingItems.insert(item, at: 0)
        }
        return item
    }

    @discardableResult
    public func addSharedText(_ text: String) throws -> SharedItem {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw SharedContentStoreError.emptyText
        }
        guard cleaned.utf8.count <= Self.maximumPersistedTextBytes else {
            throw SharedContentStoreError.textTooLarge
        }
        let item = SharedItem(
            kind: .text,
            direction: .outgoing,
            title: cleaned.count > 48 ? String(cleaned.prefix(48)) + "…" : cleaned,
            detail: cleaned,
            byteCount: Int64(cleaned.utf8.count),
            mimeType: "text/plain; charset=utf-8"
        )
        try mutate {
            outgoingItems.insert(item, at: 0)
        }
        return item
    }

    @discardableResult
    public func receiveFile(
        data: Data,
        filename: String,
        remoteAddress: String?
    ) throws -> SharedItem {
        let stagedFile = try stageReceivedFile(data: data, filename: filename)
        do {
            return try commitReceivedFile(
                stagedFile,
                remoteAddress: remoteAddress,
                notifyChange: true
            )
        } catch {
            discardStagedFile(stagedFile)
            throw error
        }
    }

    func stageReceivedFile(data: Data, filename: String) throws -> StagedIncomingFile {
        guard data.count <= Self.maximumUploadBytes else {
            throw SharedContentStoreError.fileTooLarge
        }

        let safeName = Self.sanitizeFilename(filename)
        let temporaryURL = stagingDirectory.appendingPathComponent(
            "\(UUID().uuidString).upload",
            isDirectory: false
        )
        try inboxIOLock.withLock {
            // A second app instance may have cleaned an old, idle staging
            // directory. Recreate this instance's private directory on demand.
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )
            try data.write(to: temporaryURL, options: .atomic)
        }
        return StagedIncomingFile(
            temporaryURL: temporaryURL,
            filename: safeName,
            byteCount: Int64(data.count)
        )
    }

    func commitReceivedFile(
        _ stagedFile: StagedIncomingFile,
        remoteAddress: String?,
        notifyChange: Bool
    ) throws -> SharedItem {
        let destination = try inboxIOLock.withLock {
            let destination = uniqueDestinationURL(for: stagedFile.filename)
            try FileManager.default.moveItem(at: stagedFile.temporaryURL, to: destination)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
            return destination
        }

        let item = SharedItem(
            kind: MIMEType.kind(forFileAt: destination),
            direction: .incoming,
            title: destination.lastPathComponent,
            fileURL: destination,
            byteCount: stagedFile.byteCount,
            mimeType: MIMEType.forFile(at: destination),
            remoteAddress: remoteAddress
        )
        do {
            try mutate(notifyChange: notifyChange) {
                removeInboxSuppression(for: item.fileURL)
                hiddenIncomingItemIDs.remove(item.id)
                incomingItems.insert(item, at: 0)
            }
        } catch {
            try? inboxIOLock.withLock {
                try FileManager.default.removeItem(at: destination)
            }
            throw error
        }
        return item
    }

    func discardStagedFile(_ stagedFile: StagedIncomingFile) {
        inboxIOLock.withLock {
            try? FileManager.default.removeItem(at: stagedFile.temporaryURL)
        }
    }

    @discardableResult
    public func receiveText(_ text: String, remoteAddress: String?) throws -> SharedItem {
        try receiveText(text, remoteAddress: remoteAddress, notifyChange: true)
    }

    @discardableResult
    func receiveText(
        _ text: String,
        remoteAddress: String?,
        notifyChange: Bool
    ) throws -> SharedItem {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw SharedContentStoreError.emptyText
        }
        guard cleaned.utf8.count <= Self.maximumPersistedTextBytes else {
            throw SharedContentStoreError.textTooLarge
        }
        let item = SharedItem(
            kind: .text,
            direction: .incoming,
            title: cleaned.count > 48 ? String(cleaned.prefix(48)) + "…" : cleaned,
            detail: cleaned,
            byteCount: Int64(cleaned.utf8.count),
            mimeType: "text/plain; charset=utf-8",
            remoteAddress: remoteAddress
        )
        try mutate(notifyChange: notifyChange) {
            hiddenIncomingItemIDs.remove(item.id)
            incomingItems.insert(item, at: 0)
        }
        return item
    }

    public func outgoingSnapshot() -> [SharedItem] {
        let items = lock.withLock { outgoingItems }
        return items.filter(isCurrentlyAvailable)
    }

    public func incomingSnapshot() -> [SharedItem] {
        let items = lock.withLock { incomingItems }
        return items.filter(isCurrentlyAvailable)
    }

    public func publicSnapshot() -> [SharedItem] {
        let snapshot = lock.withLock {
            (outgoingItems, incomingItems, hiddenIncomingItemIDs)
        }
        let visibleIncoming = snapshot.1.filter {
            !snapshot.2.contains($0.id) && isCurrentlyAvailable($0)
        }
        return (snapshot.0.filter(isCurrentlyAvailable) + visibleIncoming)
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func publicItem(id: UUID) -> SharedItem? {
        guard let item = logicalPublicItem(id: id), isCurrentlyAvailable(item) else {
            return nil
        }
        return item
    }

    /// Opens the selected file without following a last-component symlink.
    /// Incoming files are opened relative to the already-open Inbox directory,
    /// so replacing a path between validation and reading cannot escape it.
    public func readPublicFile(id: UUID) throws -> (item: SharedItem, data: Data) {
        guard let item = logicalPublicItem(id: id), let fileURL = item.fileURL else {
            throw SharedContentStoreError.itemNotFound
        }

        let descriptor: Int32
        if item.direction == .incoming {
            guard isDirectInboxChild(fileURL) else {
                throw SharedContentStoreError.itemNotFound
            }
            descriptor = openat(
                inboxDescriptor,
                fileURL.lastPathComponent,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
            )
        } else {
            descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw SharedContentStoreError.itemNotFound }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0,
              status.st_size <= Int64(Self.maximumUploadBytes) else {
            close(descriptor)
            throw SharedContentStoreError.itemNotFound
        }
        guard logicalPublicItem(id: id)?.fileURL == fileURL else {
            close(descriptor)
            throw SharedContentStoreError.itemNotFound
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        while data.count <= Self.maximumUploadBytes {
            let remaining = Self.maximumUploadBytes + 1 - data.count
            let chunkSize = min(1_048_576, remaining)
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        guard data.count <= Self.maximumUploadBytes,
              logicalPublicItem(id: id)?.fileURL == fileURL else {
            throw SharedContentStoreError.itemNotFound
        }
        return (item, data)
    }

    private func logicalPublicItem(id: UUID) -> SharedItem? {
        lock.withLock {
            outgoingItems.first(where: { $0.id == id })
                ?? incomingItems.first(where: {
                    $0.id == id && !hiddenIncomingItemIDs.contains($0.id)
                })
        }
    }

    @discardableResult
    public func removeOutgoing(id: UUID) -> Bool {
        (try? mutate {
            if let item = outgoingItems.first(where: { $0.id == id }) {
                suppressInboxFileIfNeeded(item.fileURL)
            }
            outgoingItems.removeAll(where: { $0.id == id })
        }) != nil
    }

    /// Removes every outgoing entry that points at the specified local file.
    /// This keeps the classroom list from retaining a broken download after a
    /// managed recording is deleted from disk.
    @discardableResult
    public func removeOutgoingFiles(at url: URL) -> Int {
        let normalizedURL = url.standardizedFileURL
        var removedCount = 0
        do {
            try mutate {
                outgoingItems
                    .filter { $0.fileURL?.standardizedFileURL == normalizedURL }
                    .forEach { suppressInboxFileIfNeeded($0.fileURL) }
                let originalCount = outgoingItems.count
                outgoingItems.removeAll { item in
                    item.fileURL?.standardizedFileURL == normalizedURL
                }
                removedCount = originalCount - outgoingItems.count
            }
        } catch {
            removedCount = 0
        }
        return removedCount
    }

    @discardableResult
    public func hideIncomingFromPublic(id: UUID) -> Bool {
        (try? mutate {
            guard incomingItems.contains(where: { $0.id == id }) else { return }
            hiddenIncomingItemIDs.insert(id)
        }) != nil
    }

    @discardableResult
    public func publishIncoming(id: UUID) -> Bool {
        (try? mutate {
            guard incomingItems.contains(where: { $0.id == id }) else { return }
            hiddenIncomingItemIDs.remove(id)
        }) != nil
    }

    @discardableResult
    public func clearOutgoing() -> Bool {
        (try? mutate {
            outgoingItems.forEach { suppressInboxFileIfNeeded($0.fileURL) }
            outgoingItems.removeAll()
        }) != nil
    }

    @discardableResult
    public func clearPublicItems() -> Bool {
        (try? mutate {
            outgoingItems.forEach { suppressInboxFileIfNeeded($0.fileURL) }
            outgoingItems.removeAll()
            hiddenIncomingItemIDs.formUnion(incomingItems.map(\.id))
        }) != nil
    }

    @discardableResult
    public func clearIncoming(deleteFiles: Bool = false) -> Bool {
        if deleteFiles {
            let items = lock.withLock { incomingItems }
            var removableIDs = Set(items.filter { $0.fileURL == nil }.map(\.id))
            var allFilesDeleted = true
            for item in items {
                guard let url = item.fileURL else { continue }
                guard isDirectInboxChild(url) else {
                    allFilesDeleted = false
                    continue
                }
                if unlinkat(inboxDescriptor, url.lastPathComponent, 0) == 0 {
                    removableIDs.insert(item.id)
                } else if errno == ENOENT {
                    removableIDs.insert(item.id)
                } else {
                    allFilesDeleted = false
                }
            }
            let didPersist = (try? mutate {
                incomingItems.removeAll { removableIDs.contains($0.id) }
                hiddenIncomingItemIDs.subtract(removableIDs)
            }) != nil
            return allFilesDeleted && didPersist
        }

        let didPersist = (try? mutate {
            // Preserve a lightweight fingerprint when the physical file is
            // kept, otherwise Inbox discovery would resurrect a deliberately
            // cleared record on the next launch.
            incomingItems.forEach { suppressInboxFileIfNeeded($0.fileURL) }
            incomingItems.removeAll()
            hiddenIncomingItemIDs.removeAll()
        }) != nil
        return didPersist
    }

    public static func sanitizeFilename(_ filename: String) -> String {
        let lastComponent = (filename as NSString).lastPathComponent
        let invalid = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
        let components = lastComponent.components(separatedBy: invalid)
        var result = components.joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if result.isEmpty || result == "." || result == ".." {
            result = "未命名文件"
        }
        if result.count > 180 {
            let extensionPart = (result as NSString).pathExtension
            let stem = (result as NSString).deletingPathExtension
            let suffix = extensionPart.isEmpty ? "" : ".\(extensionPart)"
            result = String(stem.prefix(max(1, 180 - suffix.count))) + suffix
        }
        return result
    }

    private func uniqueDestinationURL(for filename: String) -> URL {
        let original = inboxDirectory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: original.path) else {
            return original
        }

        let extensionPart = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        for index in 2...9_999 {
            let candidateName = extensionPart.isEmpty
                ? "\(stem) \(index)"
                : "\(stem) \(index).\(extensionPart)"
            let candidate = inboxDirectory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return inboxDirectory.appendingPathComponent("\(UUID().uuidString)-\(filename)")
    }

    private static func removeStaleStagingEntries(in stagingRoot: URL) {
        let fileManager = FileManager.default
        let expirationDate = Date().addingTimeInterval(-staleStagingAge)
        let entries = (try? fileManager.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for entry in entries {
            let modificationDate = try? entry.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            if let modificationDate, modificationDate < expirationDate {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    private func restorePersistedStateAndDiscoverInboxFiles() throws {
        let fileManager = FileManager.default
        let stateExists = fileManager.fileExists(atPath: persistedStateURL.path)
            || Self.isSymbolicLink(atPath: persistedStateURL.path)
        let migrationAlreadyCompleted = fileManager.fileExists(atPath: migrationMarkerURL.path)
            || Self.isSymbolicLink(atPath: migrationMarkerURL.path)
        var hideDiscoveredFiles = migrationAlreadyCompleted
        var mayReplaceStateFile = true

        if stateExists {
            if let persisted = loadPersistedState() {
                var seenIDs: Set<UUID> = []
                outgoingItems = restoredItems(
                    from: persisted.outgoingItems,
                    direction: .outgoing,
                    seenIDs: &seenIDs
                )
                incomingItems = restoredItems(
                    from: persisted.incomingItems,
                    direction: .incoming,
                    seenIDs: &seenIDs
                )

                let incomingIDs = Set(incomingItems.map(\.id))
                hiddenIncomingItemIDs = persisted.hiddenIncomingItemIDs.intersection(incomingIDs)
                suppressedInboxFiles = persisted.suppressedInboxFiles
                // Only the one-time legacy migration may publish files that
                // were found outside the persisted index. On later launches,
                // an unindexed file can be a renamed hidden item or evidence
                // of a partially damaged index, so recover it privately and
                // require an explicit re-share.
                hideDiscoveredFiles = true
            } else {
                // A damaged, oversized, or unsupported index must never make
                // previously removed files public again. Recover the Inbox in
                // the local UI, but require an explicit re-share.
                hideDiscoveredFiles = true
                do {
                    try ensureMigrationMarker()
                    mayReplaceStateFile = preserveUnreadableStateFile()
                } catch {
                    mayReplaceStateFile = false
                }
            }
        }

        discoverUnindexedInboxFiles(hideDiscovered: hideDiscoveredFiles)
        incomingItems.sort { $0.createdAt > $1.createdAt }
        if mayReplaceStateFile {
            try persistState()
        }
    }

    private func loadPersistedState() -> PersistedSharedContentState? {
        let descriptor = open(
            persistedStateURL.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0,
              status.st_size <= Self.maximumPersistedStateBytes,
              let data = try? handle.read(upToCount: Int(Self.maximumPersistedStateBytes) + 1),
              Int64(data.count) <= Self.maximumPersistedStateBytes,
              let persisted = try? JSONDecoder().decode(PersistedSharedContentState.self, from: data),
              isValid(persisted) else {
            return nil
        }
        return persisted
    }

    private func isValid(_ state: PersistedSharedContentState) -> Bool {
        guard state.version == PersistedSharedContentState.currentVersion,
              state.outgoingItems.count <= Self.maximumPersistedItems,
              state.incomingItems.count <= Self.maximumPersistedItems,
              state.hiddenIncomingItemIDs.count <= Self.maximumPersistedItems,
              state.suppressedInboxFiles.count <= Self.maximumPersistedItems else {
            return false
        }

        let allItems = state.outgoingItems + state.incomingItems
        guard allItems.count <= Self.maximumPersistedItems else { return false }
        for item in allItems {
            let hasText = item.detail != nil
            let hasFile = item.fileURL != nil
            guard hasText != hasFile else { return false }
            if let detail = item.detail {
                guard !detail.isEmpty,
                      detail.utf8.count <= Self.maximumPersistedTextBytes else {
                    return false
                }
            }
            if let fileURL = item.fileURL {
                guard fileURL.isFileURL,
                      fileURL.path.count <= Self.maximumPersistedStringCharacters else {
                    return false
                }
            }
            if let remoteAddress = item.remoteAddress,
               remoteAddress.count > Self.maximumPersistedStringCharacters {
                return false
            }
        }
        return state.suppressedInboxFiles.allSatisfy {
            !$0.filename.isEmpty
                && $0.filename.count <= Self.maximumPersistedStringCharacters
        }
    }

    private func restoredItems(
        from items: [PersistedSharedItem],
        direction: SharedItemDirection,
        seenIDs: inout Set<UUID>
    ) -> [SharedItem] {
        var seenFilePaths: Set<String> = []
        return items.compactMap { item in
            guard seenIDs.insert(item.id).inserted else { return nil }
            if let detail = item.detail {
                return makeTextItem(
                    id: item.id,
                    direction: direction,
                    detail: detail,
                    createdAt: item.createdAt,
                    remoteAddress: item.remoteAddress
                )
            }
            guard let fileURL = item.fileURL else { return nil }
            if direction == .incoming {
                guard isDirectInboxChild(fileURL),
                      seenFilePaths.insert(normalizedPath(for: fileURL)).inserted else {
                    return nil
                }
            }
            return makeFileItem(
                id: item.id,
                direction: direction,
                fileURL: fileURL,
                createdAt: item.createdAt,
                remoteAddress: item.remoteAddress
            )
        }
    }

    private func makeTextItem(
        id: UUID,
        direction: SharedItemDirection,
        detail: String,
        createdAt: Date,
        remoteAddress: String?
    ) -> SharedItem {
        SharedItem(
            id: id,
            kind: .text,
            direction: direction,
            title: detail.count > 48 ? String(detail.prefix(48)) + "…" : detail,
            detail: detail,
            byteCount: Int64(detail.utf8.count),
            mimeType: "text/plain; charset=utf-8",
            createdAt: createdAt,
            remoteAddress: remoteAddress
        )
    }

    private func makeFileItem(
        id: UUID,
        direction: SharedItemDirection,
        fileURL: URL,
        createdAt: Date,
        remoteAddress: String?
    ) -> SharedItem {
        let values = try? URL(fileURLWithPath: fileURL.path).resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        let byteCount = values?.isRegularFile == true && values?.isSymbolicLink != true
            ? values?.fileSize.map(Int64.init)
            : nil
        return SharedItem(
            id: id,
            kind: MIMEType.kind(forFileAt: fileURL),
            direction: direction,
            title: fileURL.lastPathComponent,
            fileURL: fileURL,
            byteCount: byteCount,
            mimeType: MIMEType.forFile(at: fileURL),
            createdAt: createdAt,
            remoteAddress: remoteAddress
        )
    }

    private func discoverUnindexedInboxFiles(hideDiscovered: Bool) {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
        ]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: inboxDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        let candidates = urls.compactMap { candidate -> (URL, URLResourceValues, PersistedInboxFileFingerprint)? in
            guard isDirectInboxChild(candidate),
                  let values = try? candidate.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  values.isHidden != true else {
                return nil
            }
            return (candidate, values, inboxFingerprint(for: candidate, values: values))
        }
        let currentFingerprints = Set(candidates.map(\.2))
        let currentByFilename = Dictionary(uniqueKeysWithValues: currentFingerprints.map {
            ($0.filename, $0)
        })
        // A different size or modification date at the same path is a new
        // file, so its obsolete tombstone can be discarded. Tombstones for
        // absent files are retained indefinitely: putting an old cleared file
        // back must not silently publish it.
        suppressedInboxFiles = Set(suppressedInboxFiles.filter { fingerprint in
            guard let current = currentByFilename[fingerprint.filename] else { return true }
            return fingerprint.isWildcard || current == fingerprint
        })
        var knownPaths = Set((incomingItems + outgoingItems).compactMap { item in
            item.fileURL.map(normalizedPath(for:))
        })

        for (candidate, values, fingerprint) in candidates {
            let path = normalizedPath(for: candidate)
            guard !suppressedInboxFiles.contains(where: { $0.suppresses(fingerprint) }),
                  knownPaths.insert(path).inserted else {
                continue
            }
            let item = SharedItem(
                kind: MIMEType.kind(forFileAt: candidate),
                direction: .incoming,
                title: candidate.lastPathComponent,
                fileURL: candidate,
                byteCount: values.fileSize.map(Int64.init),
                mimeType: MIMEType.forFile(at: candidate),
                createdAt: values.creationDate ?? values.contentModificationDate ?? Date()
            )
            incomingItems.append(item)
            if hideDiscovered {
                hiddenIncomingItemIDs.insert(item.id)
            }
        }
    }

    private func isDirectInboxChild(_ url: URL) -> Bool {
        normalizedPath(for: url.deletingLastPathComponent()) == normalizedPath(for: inboxDirectory)
    }

    private func normalizedPath(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func isRegularFile(at url: URL, disallowSymbolicLink: Bool) -> Bool {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        let uncachedURL = URL(fileURLWithPath: url.path, isDirectory: false)
        guard let values = try? uncachedURL.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              Int64(values.fileSize ?? 0) <= Int64(maximumUploadBytes) else {
            return false
        }
        return !disallowSymbolicLink || values.isSymbolicLink != true
    }

    private func isCurrentlyAvailable(_ item: SharedItem) -> Bool {
        if item.kind == .text {
            return item.detail?.isEmpty == false
        }
        guard let fileURL = item.fileURL else { return false }
        if item.direction == .incoming, !isDirectInboxChild(fileURL) {
            return false
        }
        return Self.isRegularFile(at: fileURL, disallowSymbolicLink: true)
    }

    private func inboxFingerprint(
        for url: URL,
        values: URLResourceValues? = nil,
        suppressedAt: Date? = nil
    ) -> PersistedInboxFileFingerprint {
        let resolvedValues = values ?? {
            let uncachedURL = URL(fileURLWithPath: url.path, isDirectory: false)
            return try? uncachedURL.resourceValues(forKeys: [
                .fileSizeKey,
                .contentModificationDateKey,
            ])
        }()
        return PersistedInboxFileFingerprint(
            filename: url.lastPathComponent,
            byteCount: resolvedValues?.fileSize.map(Int64.init),
            modificationDate: resolvedValues?.contentModificationDate,
            suppressedAt: suppressedAt
        )
    }

    private func suppressInboxFileIfNeeded(_ url: URL?) {
        guard let url, isDirectInboxChild(url) else { return }
        let fingerprint: PersistedInboxFileFingerprint
        if Self.isRegularFile(at: url, disallowSymbolicLink: true) {
            fingerprint = inboxFingerprint(for: url, suppressedAt: Date())
        } else {
            // A missing or replaced Inbox path still needs a durable tombstone;
            // otherwise an old cleared file would become public when returned.
            fingerprint = PersistedInboxFileFingerprint(
                filename: url.lastPathComponent,
                byteCount: nil,
                modificationDate: nil,
                suppressedAt: Date()
            )
        }
        suppressedInboxFiles = Set(suppressedInboxFiles.filter {
            $0.filename != fingerprint.filename
        })
        suppressedInboxFiles.insert(fingerprint)
    }

    private func removeInboxSuppression(for url: URL?) {
        guard let url, isDirectInboxChild(url) else { return }
        suppressedInboxFiles = Set(suppressedInboxFiles.filter {
            $0.filename != url.lastPathComponent
        })
    }

    private func preserveUnreadableStateFile() -> Bool {
        var status = stat()
        guard lstat(persistedStateURL.path, &status) == 0 else { return true }
        if status.st_mode & S_IFMT == S_IFLNK {
            return unlink(persistedStateURL.path) == 0
        }
        guard status.st_mode & S_IFMT == S_IFREG else { return false }
        let backupURL = persistedStateURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "SharedContent-v1.corrupt-\(UUID().uuidString).json",
                isDirectory: false
            )
        do {
            try FileManager.default.moveItem(at: persistedStateURL, to: backupURL)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: backupURL.path
            )
            pruneCorruptStateBackups()
            return true
        } catch {
            return false
        }
    }

    private func pruneCorruptStateBackups() {
        let root = persistedStateURL.deletingLastPathComponent()
        let backups = ((try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter {
                $0.lastPathComponent.hasPrefix("SharedContent-v1.corrupt-")
                    && $0.pathExtension == "json"
            }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return left > right
            }
        for backup in backups.dropFirst(Self.maximumCorruptBackups) {
            var status = stat()
            guard lstat(backup.path, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG else {
                continue
            }
            _ = unlink(backup.path)
        }
    }

    private func persistState() throws {
        try lock.withLock {
            try persistStateLocked()
        }
    }

    private func persistStateLocked() throws {
        let persisted = PersistedSharedContentState(
            version: PersistedSharedContentState.currentVersion,
            outgoingItems: outgoingItems.map(PersistedSharedItem.init),
            incomingItems: incomingItems.map(PersistedSharedItem.init),
            hiddenIncomingItemIDs: hiddenIncomingItemIDs,
            suppressedInboxFiles: suppressedInboxFiles
        )
        guard isValid(persisted) else {
            throw SharedContentStoreError.persistenceFailed
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(persisted)
            guard data.count <= Self.maximumPersistedStateBytes else {
                throw SharedContentStoreError.persistenceFailed
            }
            try ensureMigrationMarker()
            try Self.secureAtomicWrite(data, to: persistedStateURL)
        } catch {
            throw SharedContentStoreError.persistenceFailed
        }
    }

    private func ensureMigrationMarker() throws {
        var status = stat()
        if lstat(migrationMarkerURL.path, &status) == 0,
           status.st_mode & S_IFMT == S_IFREG {
            return
        }
        try Self.secureAtomicWrite(Data(), to: migrationMarkerURL)
    }

    private func mutate(notifyChange shouldNotify: Bool = true, _ body: () -> Void) throws {
        lock.lock()
        let previousOutgoingItems = outgoingItems
        let previousIncomingItems = incomingItems
        let previousHiddenIncomingItemIDs = hiddenIncomingItemIDs
        let previousSuppressedInboxFiles = suppressedInboxFiles
        body()
        do {
            try persistStateLocked()
            lock.unlock()
        } catch {
            outgoingItems = previousOutgoingItems
            incomingItems = previousIncomingItems
            hiddenIncomingItemIDs = previousHiddenIncomingItemIDs
            suppressedInboxFiles = previousSuppressedInboxFiles
            lock.unlock()
            throw error
        }
        if shouldNotify {
            notifyObservers()
        }
    }

    private static func secureAtomicWrite(_ data: Data, to destination: URL) throws {
        let temporaryURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw posixError() }
        var shouldRemoveTemporaryFile = true
        defer {
            close(descriptor)
            if shouldRemoveTemporaryFile {
                unlink(temporaryURL.path)
            }
        }

        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                guard let baseAddress = rawBuffer.baseAddress else { break }
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw posixError() }
        guard rename(temporaryURL.path, destination.path) == 0 else {
            throw posixError()
        }
        shouldRemoveTemporaryFile = false

        let directoryDescriptor = open(destination.deletingLastPathComponent().path, O_RDONLY)
        if directoryDescriptor >= 0 {
            _ = fsync(directoryDescriptor)
            close(directoryDescriptor)
        }
    }

    private static func claimStorageRoot(_ path: String) throws {
        let claimed = storageRegistryLock.withLock {
            claimedStorageRoots.insert(path).inserted
        }
        guard claimed else { throw SharedContentStoreError.storageInUse }
    }

    private static func releaseStorageRoot(_ path: String) {
        _ = storageRegistryLock.withLock {
            claimedStorageRoots.remove(path)
        }
    }

    private static func acquireStorageLock(in root: URL) throws -> Int32 {
        let lockURL = root.appendingPathComponent(".SharedContent.lock", isDirectory: false)
        let descriptor = open(
            lockURL.path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw posixError() }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw SharedContentStoreError.persistenceFailed
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            close(descriptor)
            if lockError == EWOULDBLOCK {
                throw SharedContentStoreError.storageInUse
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(lockError))
        }
        _ = fchmod(descriptor, S_IRUSR | S_IWUSR)
        return descriptor
    }

    private static func isSymbolicLink(atPath path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0 && status.st_mode & S_IFMT == S_IFLNK
    }

    private static func posixError() -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    func notifyObservers() {
        let handler = lock.withLock { changeHandler }
        handler?()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
