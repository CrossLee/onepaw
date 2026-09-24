import CryptoKit
import Darwin
import Foundation

public struct ClipboardHistoryImageMetadata: Codable, Equatable, Sendable {
    public let pasteboardType: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let byteCount: Int64
    public let fileExtension: String

    public init(
        pasteboardType: String,
        pixelWidth: Int,
        pixelHeight: Int,
        byteCount: Int64,
        fileExtension: String
    ) {
        self.pasteboardType = pasteboardType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.fileExtension = fileExtension
    }
}

public enum ClipboardHistoryContent: Codable, Equatable, Sendable {
    case text(String)
    case image(ClipboardHistoryImageMetadata)
}

public struct ClipboardHistoryItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let content: ClipboardHistoryContent
    public let contentDigest: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        content: ClipboardHistoryContent,
        contentDigest: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.content = content
        self.contentDigest = contentDigest
        self.createdAt = createdAt
    }

    public var byteCount: Int64 {
        switch content {
        case .text(let text):
            return Int64(text.utf8.count)
        case .image(let metadata):
            return metadata.byteCount
        }
    }
}

public enum ClipboardHistoryCapture: Equatable, Sendable {
    case text(String)
    case image(
        data: Data,
        pasteboardType: String,
        pixelWidth: Int,
        pixelHeight: Int,
        fileExtension: String
    )
}

public enum ClipboardHistoryStoreError: LocalizedError, Equatable, Sendable {
    case invalidCapture
    case captureExceedsDiskBudget
    case itemNotFound
    case itemIsNotImage
    case unsafeStorage
    case persistenceFailed

    public var errorDescription: String? {
        switch self {
        case .invalidCapture:
            return "剪贴板内容无效或不受支持"
        case .captureExceedsDiskBudget:
            return "单条剪贴板内容超过历史记录存储上限"
        case .itemNotFound:
            return "剪贴板历史记录不存在"
        case .itemIsNotImage:
            return "这条剪贴板历史记录不是图片"
        case .unsafeStorage:
            return "剪贴板历史记录目录不安全"
        case .persistenceFailed:
            return "无法保存剪贴板历史记录"
        }
    }
}

public actor ClipboardHistoryStore {
    public static let defaultMaximumDiskBytes: Int64 = 512 * 1_024 * 1_024

    private static let currentVersion = 1
    private static let minimumItemCount = 1
    private static let maximumAllowedItemCount = 200
    private static let maximumIndexBytes: Int64 = 8 * 1_024 * 1_024
    private static let maximumPasteboardTypeCharacters = 512
    private static let maximumImageDimension = 100_000
    private static let indexFilename = "ClipboardHistory-v1.json"
    private static let itemsDirectoryName = "Items"

    public private(set) var maximumItemCount: Int

    private let directory: URL
    private let itemsDirectory: URL
    private let indexURL: URL
    private let maximumDiskBytes: Int64
    private var items: [ClipboardHistoryItem]

    public init(
        directory: URL,
        maximumItemCount: Int = 50,
        maximumDiskBytes: Int64 = ClipboardHistoryStore.defaultMaximumDiskBytes
    ) throws {
        let normalizedDirectory = directory.standardizedFileURL
        let itemsDirectory = normalizedDirectory.appendingPathComponent(
            Self.itemsDirectoryName,
            isDirectory: true
        )
        let indexURL = normalizedDirectory.appendingPathComponent(
            Self.indexFilename,
            isDirectory: false
        )
        let clampedItemCount = Self.clampedItemCount(maximumItemCount)
        let clampedDiskBytes = max(maximumDiskBytes, 1)

        self.directory = normalizedDirectory
        self.itemsDirectory = itemsDirectory
        self.indexURL = indexURL
        self.maximumItemCount = clampedItemCount
        self.maximumDiskBytes = clampedDiskBytes
        self.items = []

        do {
            try Self.prepareStorageDirectory(normalizedDirectory)
            try Self.prepareItemsDirectory(itemsDirectory)

            let decodedItems = try Self.loadPersistedItems(from: indexURL)
            let validatedItems = try Self.validatedItems(
                decodedItems,
                in: itemsDirectory
            )
            let trimmedItems = Self.trimmedItems(
                validatedItems,
                maximumItemCount: clampedItemCount,
                maximumDiskBytes: clampedDiskBytes
            )

            try Self.persist(trimmedItems, to: indexURL)
            try Self.cleanPayloadDirectory(
                itemsDirectory,
                keeping: Set(trimmedItems.compactMap(Self.payloadFilename))
            )
            self.items = trimmedItems
        } catch let error as ClipboardHistoryStoreError {
            throw error
        } catch {
            throw ClipboardHistoryStoreError.persistenceFailed
        }
    }

    public func snapshot() -> [ClipboardHistoryItem] {
        items
    }

    @discardableResult
    public func record(
        _ capture: ClipboardHistoryCapture,
        at date: Date = Date()
    ) throws -> ClipboardHistoryItem {
        do {
            try Self.ensureStorageIsSafe(directory, itemsDirectory: itemsDirectory)

            let prepared = try Self.prepareCapture(
                capture,
                maximumDiskBytes: maximumDiskBytes
            )
            if let duplicateIndex = items.firstIndex(where: {
                $0.contentDigest == prepared.digest
            }), Self.duplicateIsUsable(
                items[duplicateIndex],
                prepared: prepared,
                itemsDirectory: itemsDirectory
            ) {
                let existing = items[duplicateIndex]
                let refreshed = ClipboardHistoryItem(
                    id: existing.id,
                    content: existing.content,
                    contentDigest: existing.contentDigest,
                    createdAt: date
                )
                var proposedItems = items
                proposedItems.remove(at: duplicateIndex)
                proposedItems.insert(refreshed, at: 0)
                proposedItems = Self.trimmedItems(
                    proposedItems,
                    maximumItemCount: maximumItemCount,
                    maximumDiskBytes: maximumDiskBytes
                )
                try commit(proposedItems)
                return refreshed
            }

            var newItem: ClipboardHistoryItem
            var createdPayloadURL: URL?
            switch prepared.content {
            case .text(let text):
                newItem = ClipboardHistoryItem(
                    content: .text(text),
                    contentDigest: prepared.digest,
                    createdAt: date
                )
            case .image(let image):
                let id = try uniqueItemID(fileExtension: image.fileExtension)
                newItem = ClipboardHistoryItem(
                    id: id,
                    content: .image(image.metadata),
                    contentDigest: prepared.digest,
                    createdAt: date
                )
                let payloadURL = Self.payloadURL(
                    for: newItem,
                    in: itemsDirectory
                )
                guard FileManager.default.createFile(
                    atPath: payloadURL.path,
                    contents: image.data,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw ClipboardHistoryStoreError.persistenceFailed
                }
                try Self.setPermissions(0o600, at: payloadURL)
                createdPayloadURL = payloadURL
            }

            var proposedItems = items
            proposedItems.removeAll { $0.contentDigest == prepared.digest }
            proposedItems.insert(newItem, at: 0)
            proposedItems = Self.trimmedItems(
                proposedItems,
                maximumItemCount: maximumItemCount,
                maximumDiskBytes: maximumDiskBytes
            )

            guard proposedItems.contains(where: { $0.id == newItem.id }) else {
                if let createdPayloadURL {
                    try? Self.removeOwnedEntry(at: createdPayloadURL)
                }
                throw ClipboardHistoryStoreError.captureExceedsDiskBudget
            }

            do {
                try commit(proposedItems)
            } catch {
                if let createdPayloadURL {
                    try? FileManager.default.removeItem(at: createdPayloadURL)
                }
                throw error
            }
            return newItem
        } catch let error as ClipboardHistoryStoreError {
            throw error
        } catch {
            throw ClipboardHistoryStoreError.persistenceFailed
        }
    }

    public func imageData(for id: UUID) throws -> Data {
        do {
            try Self.ensureStorageIsSafe(directory, itemsDirectory: itemsDirectory)
            guard let item = items.first(where: { $0.id == id }) else {
                throw ClipboardHistoryStoreError.itemNotFound
            }
            guard case .image(let metadata) = item.content else {
                throw ClipboardHistoryStoreError.itemIsNotImage
            }

            let url = Self.payloadURL(for: item, in: itemsDirectory)
            guard try Self.isSafeRegularFile(url),
                  try Self.fileSize(at: url) == metadata.byteCount else {
                throw ClipboardHistoryStoreError.itemNotFound
            }
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch let error as ClipboardHistoryStoreError {
            throw error
        } catch {
            throw ClipboardHistoryStoreError.persistenceFailed
        }
    }

    @discardableResult
    public func delete(id: UUID) throws -> Bool {
        guard items.contains(where: { $0.id == id }) else { return false }
        let proposedItems = items.filter { $0.id != id }
        try commit(proposedItems)
        return true
    }

    public func clear() throws {
        try commit([])
        do {
            try Self.cleanPayloadDirectory(itemsDirectory, keeping: [])
        } catch {
            throw ClipboardHistoryStoreError.persistenceFailed
        }
    }

    @discardableResult
    public func trim(maximumItemCount: Int) throws -> [ClipboardHistoryItem] {
        let clampedItemCount = Self.clampedItemCount(maximumItemCount)
        let proposedItems = Self.trimmedItems(
            items,
            maximumItemCount: clampedItemCount,
            maximumDiskBytes: maximumDiskBytes
        )
        try commit(proposedItems)
        self.maximumItemCount = clampedItemCount
        return items
    }

    private func uniqueItemID(fileExtension: String) throws -> UUID {
        for _ in 0 ..< 16 {
            let candidate = UUID()
            let filename = Self.payloadFilename(id: candidate, fileExtension: fileExtension)
            let url = itemsDirectory.appendingPathComponent(filename, isDirectory: false)
            if !FileManager.default.fileExists(atPath: url.path) {
                return candidate
            }
        }
        throw ClipboardHistoryStoreError.persistenceFailed
    }

    private func commit(_ proposedItems: [ClipboardHistoryItem]) throws {
        try Self.ensureStorageIsSafe(directory, itemsDirectory: itemsDirectory)
        let previousItems = items
        do {
            try Self.persist(proposedItems, to: indexURL)
            items = proposedItems
        } catch {
            items = previousItems
            throw error
        }

        let retainedIDs = Set(proposedItems.map(\.id))
        for removedItem in previousItems where !retainedIDs.contains(removedItem.id) {
            guard let url = Self.payloadURLIfImage(
                for: removedItem,
                in: itemsDirectory
            ) else {
                continue
            }
            try? Self.removeOwnedEntry(at: url)
        }
    }
}

private extension ClipboardHistoryStore {
    struct PersistedState: Codable {
        let version: Int
        let items: [ClipboardHistoryItem]
    }

    enum PreparedContent {
        case text(String)
        case image(PreparedImage)
    }

    struct PreparedImage {
        let data: Data
        let metadata: ClipboardHistoryImageMetadata

        var fileExtension: String { metadata.fileExtension }
    }

    struct PreparedCapture {
        let content: PreparedContent
        let digest: String
    }

    static func clampedItemCount(_ count: Int) -> Int {
        min(max(count, minimumItemCount), maximumAllowedItemCount)
    }

    static func prepareCapture(
        _ capture: ClipboardHistoryCapture,
        maximumDiskBytes: Int64
    ) throws -> PreparedCapture {
        switch capture {
        case .text(let text):
            guard !text.isEmpty else {
                throw ClipboardHistoryStoreError.invalidCapture
            }
            let textData = Data(text.utf8)
            guard Int64(textData.count) <= maximumDiskBytes else {
                throw ClipboardHistoryStoreError.captureExceedsDiskBudget
            }
            return PreparedCapture(
                content: .text(text),
                digest: digest(prefix: "text", data: textData)
            )

        case let .image(
            data,
            pasteboardType,
            pixelWidth,
            pixelHeight,
            requestedExtension
        ):
            guard !data.isEmpty,
                  Int64(data.count) <= maximumDiskBytes,
                  isValidPasteboardType(pasteboardType),
                  pixelWidth > 0,
                  pixelHeight > 0,
                  pixelWidth <= maximumImageDimension,
                  pixelHeight <= maximumImageDimension,
                  let fileExtension = normalizedFileExtension(requestedExtension) else {
                if Int64(data.count) > maximumDiskBytes {
                    throw ClipboardHistoryStoreError.captureExceedsDiskBudget
                }
                throw ClipboardHistoryStoreError.invalidCapture
            }

            let metadata = ClipboardHistoryImageMetadata(
                pasteboardType: pasteboardType,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                byteCount: Int64(data.count),
                fileExtension: fileExtension
            )
            return PreparedCapture(
                content: .image(PreparedImage(data: data, metadata: metadata)),
                digest: digest(prefix: "image", data: data)
            )
        }
    }

    static func duplicateIsUsable(
        _ item: ClipboardHistoryItem,
        prepared: PreparedCapture,
        itemsDirectory: URL
    ) -> Bool {
        switch (item.content, prepared.content) {
        case (.text(let existing), .text(let candidate)):
            return existing == candidate
        case (.image(let metadata), .image(let candidate)):
            guard metadata.byteCount == candidate.metadata.byteCount,
                  let url = payloadURLIfImage(for: item, in: itemsDirectory),
                  (try? isSafeRegularFile(url)) == true,
                  (try? fileSize(at: url)) == metadata.byteCount else {
                return false
            }
            return true
        case (.text, .image), (.image, .text):
            return false
        }
    }

    static func digest(prefix: String, data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(prefix.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func trimmedItems(
        _ sourceItems: [ClipboardHistoryItem],
        maximumItemCount: Int,
        maximumDiskBytes: Int64
    ) -> [ClipboardHistoryItem] {
        var result = Array(sourceItems.prefix(clampedItemCount(maximumItemCount)))
        var totalBytes = result.reduce(Int64(0)) { partial, item in
            let (sum, overflow) = partial.addingReportingOverflow(item.byteCount)
            return overflow ? Int64.max : sum
        }
        while totalBytes > maximumDiskBytes, let removed = result.popLast() {
            totalBytes = max(totalBytes - removed.byteCount, 0)
        }
        return prefixThatFitsIndex(result)
    }

    /// Text lives directly in the JSON index. Keep the newest prefix that can
    /// be persisted so reaching the defensive index-size limit never causes
    /// all subsequent copies to fail. Encoding each item separately avoids
    /// repeatedly materializing a potentially large complete index.
    static func prefixThatFitsIndex(
        _ sourceItems: [ClipboardHistoryItem]
    ) -> [ClipboardHistoryItem] {
        let encoder = makeEncoder()
        guard let emptyStateSize = try? encoder.encode(
            PersistedState(version: currentVersion, items: [])
        ).count else {
            return []
        }

        // The empty state's `[]` is replaced by the encoded item bytes.
        var estimatedSize = max(emptyStateSize - 2, 0)
        var result: [ClipboardHistoryItem] = []
        result.reserveCapacity(sourceItems.count)

        for item in sourceItems {
            guard let itemSize = try? encoder.encode(item).count else { break }
            let separatorSize = result.isEmpty ? 0 : 1
            let (withSeparator, separatorOverflow) = estimatedSize
                .addingReportingOverflow(separatorSize)
            let (candidateSize, itemOverflow) = withSeparator
                .addingReportingOverflow(itemSize)
            guard !separatorOverflow,
                  !itemOverflow,
                  Int64(candidateSize) <= maximumIndexBytes else {
                break
            }
            estimatedSize = candidateSize
            result.append(item)
        }

        // Keep the actual encoded form authoritative if an encoder detail ever
        // makes the estimate differ from the enclosing state representation.
        while !result.isEmpty {
            guard let encodedSize = try? encoder.encode(
                PersistedState(version: currentVersion, items: result)
            ).count else {
                result.removeLast()
                continue
            }
            if Int64(encodedSize) <= maximumIndexBytes { break }
            result.removeLast()
        }
        return result
    }

    static func loadPersistedItems(from indexURL: URL) throws -> [ClipboardHistoryItem] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }

        guard try isSafeRegularFile(indexURL),
              try fileSize(at: indexURL) <= maximumIndexBytes else {
            try removeOwnedEntry(at: indexURL)
            return []
        }

        do {
            let data = try Data(contentsOf: indexURL, options: [.mappedIfSafe])
            let state = try JSONDecoder().decode(PersistedState.self, from: data)
            guard state.version == currentVersion else {
                try removeOwnedEntry(at: indexURL)
                return []
            }
            return state.items
        } catch {
            try? removeOwnedEntry(at: indexURL)
            return []
        }
    }

    static func validatedItems(
        _ sourceItems: [ClipboardHistoryItem],
        in itemsDirectory: URL
    ) throws -> [ClipboardHistoryItem] {
        var seenIDs: Set<UUID> = []
        var seenDigests: Set<String> = []
        var result: [ClipboardHistoryItem] = []
        result.reserveCapacity(min(sourceItems.count, maximumAllowedItemCount))

        for item in sourceItems {
            guard !seenIDs.contains(item.id),
                  !seenDigests.contains(item.contentDigest),
                  isValidDigest(item.contentDigest) else {
                continue
            }

            switch item.content {
            case .text(let text):
                guard !text.isEmpty,
                      digest(prefix: "text", data: Data(text.utf8)) == item.contentDigest else {
                    continue
                }
            case .image(let metadata):
                guard isValidImageMetadata(metadata),
                      let url = payloadURLIfImage(for: item, in: itemsDirectory),
                      try isSafeRegularFile(url),
                      try fileSize(at: url) == metadata.byteCount else {
                    continue
                }
            }

            seenIDs.insert(item.id)
            seenDigests.insert(item.contentDigest)
            result.append(item)
        }
        return result
    }

    static func persist(_ items: [ClipboardHistoryItem], to indexURL: URL) throws {
        let state = PersistedState(version: currentVersion, items: items)
        let encoder = makeEncoder()
        let data = try encoder.encode(state)
        guard Int64(data.count) <= maximumIndexBytes else {
            throw ClipboardHistoryStoreError.persistenceFailed
        }

        if FileManager.default.fileExists(atPath: indexURL.path),
           try !isSafeRegularFile(indexURL) {
            throw ClipboardHistoryStoreError.unsafeStorage
        }
        try data.write(to: indexURL, options: .atomic)
        try setPermissions(0o600, at: indexURL)
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func prepareStorageDirectory(_ directory: URL) throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            guard try isSafeDirectory(directory) else {
                throw ClipboardHistoryStoreError.unsafeStorage
            }
        } else {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try setPermissions(0o700, at: directory)
    }

    static func prepareItemsDirectory(_ itemsDirectory: URL) throws {
        if FileManager.default.fileExists(atPath: itemsDirectory.path) {
            if try !isSafeDirectory(itemsDirectory) {
                try removeOwnedEntry(at: itemsDirectory)
                try FileManager.default.createDirectory(
                    at: itemsDirectory,
                    withIntermediateDirectories: false
                )
            }
        } else {
            try FileManager.default.createDirectory(
                at: itemsDirectory,
                withIntermediateDirectories: false
            )
        }
        try setPermissions(0o700, at: itemsDirectory)
    }

    static func ensureStorageIsSafe(
        _ directory: URL,
        itemsDirectory: URL
    ) throws {
        guard try isSafeDirectory(directory),
              try isSafeDirectory(itemsDirectory) else {
            throw ClipboardHistoryStoreError.unsafeStorage
        }
    }

    static func cleanPayloadDirectory(
        _ itemsDirectory: URL,
        keeping retainedFilenames: Set<String>
    ) throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: itemsDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        for entry in entries where !retainedFilenames.contains(entry.lastPathComponent) {
            try removeOwnedEntry(at: entry)
        }
    }

    static func payloadFilename(_ item: ClipboardHistoryItem) -> String? {
        guard case .image(let metadata) = item.content,
              normalizedFileExtension(metadata.fileExtension) == metadata.fileExtension else {
            return nil
        }
        return payloadFilename(id: item.id, fileExtension: metadata.fileExtension)
    }

    static func payloadFilename(id: UUID, fileExtension: String) -> String {
        "\(id.uuidString.lowercased()).\(fileExtension)"
    }

    static func payloadURL(
        for item: ClipboardHistoryItem,
        in itemsDirectory: URL
    ) -> URL {
        let filename = payloadFilename(item) ?? item.id.uuidString.lowercased()
        return itemsDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    static func payloadURLIfImage(
        for item: ClipboardHistoryItem,
        in itemsDirectory: URL
    ) -> URL? {
        guard let filename = payloadFilename(item) else { return nil }
        let url = itemsDirectory.appendingPathComponent(filename, isDirectory: false)
        guard url.deletingLastPathComponent().standardizedFileURL
            == itemsDirectory.standardizedFileURL else {
            return nil
        }
        return url
    }

    static func isValidImageMetadata(_ metadata: ClipboardHistoryImageMetadata) -> Bool {
        metadata.byteCount > 0
            && metadata.pixelWidth > 0
            && metadata.pixelHeight > 0
            && metadata.pixelWidth <= maximumImageDimension
            && metadata.pixelHeight <= maximumImageDimension
            && isValidPasteboardType(metadata.pasteboardType)
            && normalizedFileExtension(metadata.fileExtension) == metadata.fileExtension
    }

    static func isValidPasteboardType(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= maximumPasteboardTypeCharacters
            && !value.utf8.contains(0)
    }

    static func normalizedFileExtension(_ value: String) -> String? {
        let normalized = value.lowercased()
        guard (1 ... 10).contains(normalized.utf8.count),
              normalized.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 122)
              }) else {
            return nil
        }
        return normalized
    }

    static func isValidDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    static func setPermissions(_ permissions: Int, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    static func fileSize(at url: URL) throws -> Int64 {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            throw ClipboardHistoryStoreError.persistenceFailed
        }
        return information.st_size
    }

    static func isSafeDirectory(_ url: URL) throws -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        let kind = information.st_mode & mode_t(S_IFMT)
        return kind == mode_t(S_IFDIR)
    }

    static func isSafeRegularFile(_ url: URL) throws -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        let kind = information.st_mode & mode_t(S_IFMT)
        return kind == mode_t(S_IFREG)
    }

    static func removeOwnedEntry(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}
