import AppKit
import Carbon.HIToolbox
import CrossToolCore
import Foundation
import ImageIO
import SwiftUI

enum ClipboardHistoryPasteboardAccessState: Equatable, Sendable {
    case legacyAllowed
    case notRequested
    case askEveryTime
    case alwaysAllowed
    case denied

    var allowsAutomaticReadAttempt: Bool {
        switch self {
        case .legacyAllowed, .notRequested, .alwaysAllowed:
            return true
        case .askEveryTime, .denied:
            return false
        }
    }

    /// A successful candidate read has already been authorized for its current
    /// pasteboard generation. macOS changes `.default` to `.ask` after the
    /// first one-time approval, so that transition must not discard content
    /// the user just explicitly allowed.
    var allowsAuthorizedGenerationCommit: Bool {
        self != .denied
    }

    var guidance: String? {
        switch self {
        case .legacyAllowed, .alwaysAllowed:
            return nil
        case .notRequested:
            return "首次记录复制内容时，macOS 会询问是否允许一爪读取剪贴板。"
        case .askEveryTime:
            return "macOS 当前设为“每次询问”。一爪已暂停后台读取以避免反复弹窗；请在“隐私与安全性”中改为“始终允许”。"
        case .denied:
            return "macOS 已禁止一爪读取剪贴板。请在“隐私与安全性”中改为“始终允许”。"
        }
    }

    var needsSettingsButton: Bool {
        self == .askEveryTime || self == .denied
    }
}

@MainActor
final class ClipboardHistoryFeatureModel: ObservableObject {
    static let enabledDefaultsKey = "clipboardHistory.enabled.v1"
    static let maximumItemCountDefaultsKey = "clipboardHistory.maximumItemCount.v1"
    static let defaultMaximumItemCount = 50
    static let allowedMaximumItemCount = 1 ... 200

    @Published private(set) var items: [ClipboardHistoryItem] = []
    @Published private(set) var isEnabled: Bool
    @Published private(set) var maximumItemCount: Int
    @Published private(set) var lastError: String?
    @Published private(set) var pasteboardAccessState: ClipboardHistoryPasteboardAccessState

    private let pasteboard: NSPasteboard
    private let defaults: UserDefaults
    private let observationGate: ClipboardHistoryObservationGate
    private let secureInputChecker: @MainActor @Sendable () -> Bool
    private let store: ClipboardHistoryStore?
    private let captureProcessor: any ClipboardHistoryCaptureProcessing
    private let imageDecoder = ClipboardHistoryImageDecoder()
    private var monitorTask: Task<Void, Never>?
    private var lastSeenChangeCount: Int?
    private var captureRevision: UInt64 = 0
    private var maximumItemCountRevision: UInt64 = 0
    private var thumbnails: [UUID: NSImage] = [:]

    init(
        directory: URL,
        defaults: UserDefaults = .standard,
        pasteboard: NSPasteboard = .general,
        observationGate: ClipboardHistoryObservationGate,
        secureInputChecker: @escaping @MainActor @Sendable () -> Bool = {
            IsSecureEventInputEnabled()
        },
        captureProcessor: (any ClipboardHistoryCaptureProcessing)? = nil
    ) {
        self.defaults = defaults
        self.pasteboard = pasteboard
        self.observationGate = observationGate
        self.secureInputChecker = secureInputChecker
        self.captureProcessor = captureProcessor ?? ClipboardHistoryCaptureProcessor()
        self.pasteboardAccessState = Self.accessState(for: pasteboard)

        let savedEnabled = defaults.object(forKey: Self.enabledDefaultsKey) as? Bool
        isEnabled = savedEnabled ?? true

        let savedMaximum = defaults.object(
            forKey: Self.maximumItemCountDefaultsKey
        ) as? NSNumber
        let normalizedMaximum = Self.normalizedMaximumItemCount(
            savedMaximum?.intValue ?? Self.defaultMaximumItemCount
        )
        maximumItemCount = normalizedMaximum

        do {
            store = try ClipboardHistoryStore(
                directory: directory,
                maximumItemCount: normalizedMaximum
            )
            lastError = nil
        } catch {
            store = nil
            lastError = "复制记录目录暂时不可用，当前不会保存新的复制内容。"
        }
    }

    func start() {
        guard monitorTask == nil else { return }
        // Establish a baseline instead of importing whatever happened to be on
        // the clipboard before OnePaw started.
        lastSeenChangeCount = pasteboard.changeCount
        monitorTask = Task { [weak self] in
            guard let self else { return }
            await reload()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(350))
                } catch {
                    return
                }
                await pollNow()
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        captureRevision &+= 1
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
        // Enabling history should not import content copied while it was off.
        lastSeenChangeCount = pasteboard.changeCount
        lastError = nil
    }

    func setMaximumItemCount(_ requestedValue: Int) {
        let normalizedValue = Self.normalizedMaximumItemCount(requestedValue)
        guard maximumItemCount != normalizedValue else { return }
        maximumItemCountRevision &+= 1
        let revision = maximumItemCountRevision
        maximumItemCount = normalizedValue
        defaults.set(normalizedValue, forKey: Self.maximumItemCountDefaultsKey)
        guard let store else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  self.maximumItemCountRevision == revision else {
                return
            }
            do {
                _ = try await store.trim(maximumItemCount: normalizedValue)
                guard self.maximumItemCountRevision == revision else { return }
                await self.reload()
            } catch {
                guard self.maximumItemCountRevision == revision else { return }
                self.lastError = "无法调整复制记录数量，请检查磁盘空间和文件权限。"
            }
        }
    }

    func pollNow() async {
        refreshPasteboardAccessState()
        let observedChangeCount = pasteboard.changeCount
        guard observedChangeCount != lastSeenChangeCount else { return }
        lastSeenChangeCount = observedChangeCount

        guard isEnabled, let store else { return }
        let gateObservation = observationGate.observation
        let observedCaptureRevision = captureRevision
        guard !gateObservation.isSuppressed,
              !observationGate.shouldSuppress(changeCount: observedChangeCount),
              pasteboardAccessState.allowsAutomaticReadAttempt,
              !secureInputChecker() else {
            return
        }

        // AppKit requires promised pasteboard data to be materialized on the
        // main thread. Read a single candidate here, then move validation and
        // ImageIO header probing to a serial background actor.
        guard let candidate = ClipboardHistoryPasteboardReader.candidate(
            from: pasteboard,
            expectedChangeCount: observedChangeCount
        ),
        pasteboard.changeCount == observedChangeCount,
        observationGate.canCommit(observation: gateObservation) else {
            refreshPasteboardAccessState()
            return
        }
        refreshPasteboardAccessState()
        guard pasteboardAccessState.allowsAuthorizedGenerationCommit else { return }

        let capture = await captureProcessor.capture(from: candidate)
        guard let capture,
              isEnabled,
              captureRevision == observedCaptureRevision,
              pasteboardAccessState.allowsAuthorizedGenerationCommit,
              pasteboard.changeCount == observedChangeCount,
              observationGate.canCommit(observation: gateObservation) else {
            return
        }

        do {
            _ = try await store.record(capture)
            await reload()
            lastError = nil
        } catch {
            lastError = "无法保存这条复制记录，请检查磁盘空间和文件权限。"
        }
    }

    /// Records an image OnePaw has already materialized for automatic
    /// screenshot copy. The matching pasteboard item carries an auto-generated
    /// marker, so history must reuse these bytes instead of asking AppKit to
    /// return the complete PNG on the main thread.
    func recordAutomaticallyCopiedScreenshotPNG(_ pngData: Data) async {
        // Keep the same privacy boundary as pasteboard polling. macOS enables
        // Secure Input around password and other protected fields; clipboard
        // history must not persist a screenshot through this direct fast path
        // while that protection is active.
        guard isEnabled, !secureInputChecker(), let store else { return }
        let observedCaptureRevision = captureRevision
        let candidate = ClipboardHistoryPasteboardCandidate.image(
            data: pngData,
            pasteboardType: NSPasteboard.PasteboardType.png.rawValue,
            fileExtension: "png"
        )
        guard let capture = await captureProcessor.capture(from: candidate),
              isEnabled,
              !secureInputChecker(),
              captureRevision == observedCaptureRevision else {
            return
        }

        do {
            _ = try await store.record(capture)
            guard isEnabled, captureRevision == observedCaptureRevision else { return }
            await reload()
            lastError = nil
        } catch {
            guard isEnabled, captureRevision == observedCaptureRevision else { return }
            lastError = "无法保存这条复制记录，请检查磁盘空间和文件权限。"
        }
    }

    func copy(_ item: ClipboardHistoryItem) async {
        guard let store else { return }
        do {
            switch item.content {
            case .text(let text):
                try observationGate.performSuppressedWrite(to: pasteboard) {
                    pasteboard.clearContents()
                    guard pasteboard.setString(text, forType: .string) else {
                        throw ClipboardHistoryFeatureError.pasteboardWriteFailed
                    }
                }
            case .image(let metadata):
                let data = try await store.imageData(for: item.id)
                try observationGate.performSuppressedWrite(to: pasteboard) {
                    let pasteboardItem = NSPasteboardItem()
                    let type = NSPasteboard.PasteboardType(metadata.pasteboardType)
                    guard pasteboardItem.setData(data, forType: type) else {
                        throw ClipboardHistoryFeatureError.pasteboardWriteFailed
                    }
                    pasteboard.clearContents()
                    guard pasteboard.writeObjects([pasteboardItem]) else {
                        throw ClipboardHistoryFeatureError.pasteboardWriteFailed
                    }
                }
            }
            lastError = nil
        } catch {
            lastError = "无法复制这条记录，它的内容可能已损坏或丢失。"
        }
    }

    func delete(_ item: ClipboardHistoryItem) async {
        guard let store else { return }
        do {
            _ = try await store.delete(id: item.id)
            thumbnails[item.id] = nil
            await reload()
            lastError = nil
        } catch {
            lastError = "无法删除这条复制记录。"
        }
    }

    func clear() async {
        // Invalidate any candidate currently being validated off the main
        // actor so it cannot reappear after the user clears the history.
        captureRevision &+= 1
        lastSeenChangeCount = pasteboard.changeCount
        guard let store else { return }
        do {
            try await store.clear()
            thumbnails.removeAll()
            await reload()
            lastError = nil
        } catch {
            lastError = "无法清空复制记录。"
        }
    }

    func thumbnail(for item: ClipboardHistoryItem) async -> NSImage? {
        guard case .image = item.content, let store else { return nil }
        if let cached = thumbnails[item.id] { return cached }
        guard let data = try? await store.imageData(for: item.id),
              let decoded = await imageDecoder.decode(data, maximumPixelSize: 192) else {
            return nil
        }
        let image = decoded.image
        let thumbnail = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        thumbnails[item.id] = thumbnail
        return thumbnail
    }

    func detailImage(for item: ClipboardHistoryItem) async -> NSImage? {
        guard case .image = item.content, let store else { return nil }
        guard let data = try? await store.imageData(for: item.id),
              let decoded = await imageDecoder.decode(
                  data,
                  maximumPixelSize: 3_072
              ) else {
            return nil
        }
        let image = decoded.image
        return NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
    }

    func reload() async {
        guard let store else { return }
        let latestItems = await store.snapshot()
        let retainedIDs = Set(latestItems.map(\.id))
        thumbnails = thumbnails.filter { retainedIDs.contains($0.key) }
        items = latestItems
    }

    func suppressSensitivePasteboardWrite(_ body: () -> Void) {
        observationGate.performSuppressedWrite(to: pasteboard, body)
    }

    func openPasteboardPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func refreshPasteboardAccessState() {
        let newState = Self.accessState(for: pasteboard)
        if newState != pasteboardAccessState {
            pasteboardAccessState = newState
        }
    }

    private static func accessState(
        for pasteboard: NSPasteboard
    ) -> ClipboardHistoryPasteboardAccessState {
        if #available(macOS 15.4, *) {
            switch pasteboard.accessBehavior {
            case .default:
                return .notRequested
            case .ask:
                return .askEveryTime
            case .alwaysAllow:
                return .alwaysAllowed
            case .alwaysDeny:
                return .denied
            @unknown default:
                return .denied
            }
        }
        return .legacyAllowed
    }

    private static func normalizedMaximumItemCount(_ value: Int) -> Int {
        min(max(value, allowedMaximumItemCount.lowerBound), allowedMaximumItemCount.upperBound)
    }
}

private struct ClipboardHistoryDecodedImage: @unchecked Sendable {
    let image: CGImage
}

enum ClipboardHistoryPasteboardCandidate: Equatable, Sendable {
    case text(String)
    case image(data: Data, pasteboardType: String, fileExtension: String)
}

protocol ClipboardHistoryCaptureProcessing: Sendable {
    func capture(
        from candidate: ClipboardHistoryPasteboardCandidate
    ) async -> ClipboardHistoryCapture?
}

/// CPU-bound validation stays serialized away from the main actor. AppKit
/// pasteboard reads themselves remain on the main actor because promised-data
/// providers are not safe to fulfill from a background thread.
private actor ClipboardHistoryCaptureProcessor: ClipboardHistoryCaptureProcessing {
    private static let maximumTextBytes = 1 * 1_024 * 1_024
    private static let maximumImageBytes = 25 * 1_024 * 1_024
    private static let maximumImageDimension = 20_000
    private static let maximumImagePixels = 50_000_000

    func capture(
        from candidate: ClipboardHistoryPasteboardCandidate
    ) async -> ClipboardHistoryCapture? {
        switch candidate {
        case .text(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.lengthOfBytes(using: .utf8) <= Self.maximumTextBytes else {
                return nil
            }
            return .text(text)

        case .image(let data, let pasteboardType, let fileExtension):
            guard let dimensions = Self.validImageDimensions(
                for: data,
                expectedType: pasteboardType
            ) else {
                return nil
            }
            return .image(
                data: data,
                pasteboardType: pasteboardType,
                pixelWidth: dimensions.width,
                pixelHeight: dimensions.height,
                fileExtension: fileExtension
            )
        }
    }

    private static func validImageDimensions(
        for data: Data,
        expectedType: String
    ) -> (width: Int, height: Int)? {
        guard !data.isEmpty,
              data.count <= maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              (CGImageSourceGetType(source) as String?) == expectedType,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source,
                  0,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0,
              width <= maximumImageDimension,
              height <= maximumImageDimension,
              width <= maximumImagePixels / height else {
            return nil
        }
        return (width, height)
    }
}

/// ImageIO work is serialized away from the main actor so opening a long
/// image history cannot launch hundreds of full-cost decodes on the UI thread.
private actor ClipboardHistoryImageDecoder {
    func decode(
        _ data: Data,
        maximumPixelSize: Int
    ) -> ClipboardHistoryDecodedImage? {
        guard !Task.isCancelled else { return nil }
        let boundedPixelSize = min(max(maximumPixelSize, 1), 4_096)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceShouldCacheImmediately: true,
                      kCGImageSourceThumbnailMaxPixelSize: boundedPixelSize,
                  ] as CFDictionary
              ) else {
            return nil
        }
        guard !Task.isCancelled else { return nil }
        return ClipboardHistoryDecodedImage(image: image)
    }
}

private enum ClipboardHistoryFeatureError: Error {
    case pasteboardWriteFailed
}

enum ClipboardHistoryPasteboardType {
    static let autoGenerated = NSPasteboard.PasteboardType(
        "org.nspasteboard.AutoGeneratedType"
    )
}

enum ClipboardHistoryPasteboardReader {
    private static let jpegType = NSPasteboard.PasteboardType("public.jpeg")
    private static let forbiddenTypeNames: Set<String> = [
        NSPasteboard.PasteboardType.fileURL.rawValue,
        "NSFilenamesPboardType",
        "com.apple.pasteboard.promised-file-url",
        "com.apple.filepromise",
        "com.apple.filepromise.content",
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        ClipboardHistoryPasteboardType.autoGenerated.rawValue,
    ]

    @MainActor
    static func candidate(
        from pasteboard: NSPasteboard,
        expectedChangeCount: Int
    ) -> ClipboardHistoryPasteboardCandidate? {
        guard pasteboard.changeCount == expectedChangeCount,
              let items = pasteboard.pasteboardItems,
              items.count == 1,
              let item = items.first else {
            return nil
        }

        let typeNames = Set(item.types.map(\.rawValue))
        guard forbiddenTypeNames.isDisjoint(with: typeNames) else { return nil }

        let imageRepresentations: [(
            type: NSPasteboard.PasteboardType,
            fileExtension: String
        )] = [
            (.png, "png"),
            (jpegType, "jpg"),
            (.tiff, "tiff"),
        ]
        for representation in imageRepresentations where item.types.contains(representation.type) {
            guard let data = item.data(forType: representation.type) else {
                return nil
            }
            return .image(
                data: Data(data),
                pasteboardType: representation.type.rawValue,
                fileExtension: representation.fileExtension
            )
        }

        guard item.types.contains(.string),
              let text = item.string(forType: .string) else {
            return nil
        }
        return .text(text)
    }
}

private enum HistorySegment: String, CaseIterable, Identifiable {
    case clipboard = "复制记录"
    case sharing = "分享记录"

    var id: String { rawValue }
}

struct HistoryPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var segment: HistorySegment = .clipboard

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "历史记录",
                    subtitle: "复制内容和课堂分享记录均保存在本机"
                )
                Picker("记录类型", selection: $segment) {
                    ForEach(HistorySegment.allCases) { segment in
                        Text(segment.rawValue).tag(segment)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch segment {
                case .clipboard:
                    ClipboardHistoryListContent(model: model.clipboardHistory)
                case .sharing:
                    SharingHistoryContent()
                }
            }
            .padding(30)
        }
    }
}

private struct ClipboardHistoryListContent: View {
    @ObservedObject var model: ClipboardHistoryFeatureModel
    @State private var showingClearConfirmation = false
    @State private var selectedItem: ClipboardHistoryItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text("复制记录仅保存在这台 Mac，不会上传或加入课堂共享区。系统标记为私密或临时的内容不会保存；未标记的普通文字仍可能被记录。快捷翻译的临时复制会隔离处理；若第三方 App 超过 5 秒才响应，macOS 无法再可靠区分它与新的手动复制。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(Color.crossToolAccent)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.crossToolAccent.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if let guidance = model.pasteboardAccessState.guidance {
                HStack(spacing: 12) {
                    Label(guidance, systemImage: "hand.raised")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    if model.pasteboardAccessState.needsSettingsButton {
                        Button("打开系统设置") {
                            model.openPasteboardPrivacySettings()
                        }
                    }
                }
                .padding(14)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if let lastError = model.lastError {
                Label(lastError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            ContentSection(
                title: "最近复制 \(model.items.count)/\(model.maximumItemCount)"
            ) {
                if model.items.isEmpty {
                    EmptyContentRow(
                        systemImage: model.isEnabled ? "doc.on.clipboard" : "pause.circle",
                        text: model.isEnabled
                            ? "复制文字或图片后，会显示在这里"
                            : "复制记录已停用，可在设置中重新开启"
                    )
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(model.items) { item in
                            ClipboardHistoryRow(
                                item: item,
                                model: model,
                                onOpen: { selectedItem = item }
                            )
                            if item.id != model.items.last?.id { Divider() }
                        }
                    }
                }
            }

            HStack {
                Text("最多保留 \(model.maximumItemCount) 条，可在设置中调整。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清空复制记录", systemImage: "trash", role: .destructive) {
                    showingClearConfirmation = true
                }
                .disabled(model.items.isEmpty)
            }
        }
        .confirmationDialog(
            "确定清空全部复制记录？",
            isPresented: $showingClearConfirmation
        ) {
            Button("清空", role: .destructive) {
                Task { await model.clear() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会删除本机保存的文字和图片复制记录，无法撤销。")
        }
        .sheet(item: $selectedItem) { item in
            ClipboardHistoryDetailSheet(item: item, model: model)
        }
    }
}

private struct ClipboardHistoryRow: View {
    let item: ClipboardHistoryItem
    @ObservedObject var model: ClipboardHistoryFeatureModel
    let onOpen: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 14) {
                    preview
                    VStack(alignment: .leading, spacing: 5) {
                        summary
                        HStack(spacing: 5) {
                            detail
                            Text("·")
                            Text(item.createdAt, style: .relative)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("查看完整内容")
            .accessibilityLabel(detailAccessibilityLabel)
            .accessibilityHint("打开弹窗查看完整内容")

            Button("复制", systemImage: "doc.on.doc") {
                Task { await model.copy(item) }
            }
            .labelStyle(.iconOnly)
            .help("复制回剪贴板")
            .accessibilityLabel("复制回剪贴板")
            Button("删除", systemImage: "trash", role: .destructive) {
                Task { await model.delete(item) }
            }
            .labelStyle(.iconOnly)
            .help("删除这条记录")
            .accessibilityLabel("删除这条记录")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .task(id: item.id) {
            thumbnail = await model.thumbnail(for: item)
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch item.content {
        case .text:
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.crossToolAccent.opacity(0.09))
                .frame(width: 64, height: 48)
                .overlay {
                    Image(systemName: "text.alignleft")
                        .foregroundStyle(Color.crossToolAccent)
                }
        case .image:
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 64, height: 48)
            .background(Color.secondary.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
    }

    @ViewBuilder
    private var summary: some View {
        switch item.content {
        case .text(let text):
            Text(Self.previewText(text))
                .lineLimit(2)
        case .image:
            Text("图片")
                .fontWeight(.medium)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch item.content {
        case .text(let text):
            Text("\(text.count) 个字符")
        case .image(let metadata):
            Text(
                "\(metadata.pixelWidth) × \(metadata.pixelHeight) · "
                    + ByteCountFormatter.string(
                        fromByteCount: metadata.byteCount,
                        countStyle: .file
                    )
            )
        }
    }

    private static func previewText(_ text: String) -> String {
        let previewLimit = 320
        guard text.count > previewLimit else { return text }
        return String(text.prefix(previewLimit)) + "…"
    }

    private var detailAccessibilityLabel: String {
        switch item.content {
        case .text(let text):
            let summary = Self.previewText(text)
                .replacingOccurrences(of: "\n", with: " ")
            return "查看完整文字内容，\(summary)，\(text.count) 个字符，\(formattedCreatedAt)"
        case .image(let metadata):
            let size = ByteCountFormatter.string(
                fromByteCount: metadata.byteCount,
                countStyle: .file
            )
            return "查看完整图片，\(metadata.pixelWidth) × \(metadata.pixelHeight)，\(size)，\(formattedCreatedAt)"
        }
    }

    private var formattedCreatedAt: String {
        item.createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct ClipboardHistoryDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: ClipboardHistoryItem
    @ObservedObject var model: ClipboardHistoryFeatureModel
    @State private var detailImage: NSImage?
    @State private var isLoadingImage = false
    @State private var imageLoadFailed = false
    @State private var copyFeedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: iconName)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(item.createdAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(metadataDescription)
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                if let copyFeedback {
                    Label(
                        copyFeedback,
                        systemImage: model.lastError == nil
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(model.lastError == nil ? .green : .red)
                } else {
                    Text(usageHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("复制完整内容", systemImage: "doc.on.doc") {
                    Task {
                        await model.copy(item)
                        copyFeedback = model.lastError ?? "已复制到剪贴板"
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(copyButtonIsDisabled)
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 620)
        .task(id: item.id) {
            await loadImageIfNeeded()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.content {
        case .text(let text):
            ClipboardHistoryTextDetailView(text: text)
                .background(Color.secondary.opacity(0.045))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.crossToolBorder, lineWidth: 1)
                }

        case .image(let metadata):
            Group {
                if let detailImage {
                    GeometryReader { geometry in
                        Image(nsImage: detailImage)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(
                                width: max(geometry.size.width - 24, 1),
                                height: max(geometry.size.height - 24, 1)
                            )
                            .padding(12)
                            .accessibilityLabel(
                                "完整复制图片，尺寸 \(metadata.pixelWidth) × \(metadata.pixelHeight)"
                            )
                    }
                } else if isLoadingImage {
                    ProgressView("正在载入图片…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if imageLoadFailed {
                    ContentUnavailableView(
                        "无法显示图片",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text("图片文件可能已损坏或被移除。")
                    )
                }
            }
            .background(Color.secondary.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.crossToolBorder, lineWidth: 1)
            }
        }
    }

    private var title: String {
        switch item.content {
        case .text: "完整文字"
        case .image: "完整图片"
        }
    }

    private var iconName: String {
        switch item.content {
        case .text: "text.alignleft"
        case .image: "photo"
        }
    }

    private var metadataDescription: String {
        switch item.content {
        case .text(let text):
            "\(text.count) 个字符"
        case .image(let metadata):
            "\(metadata.pixelWidth) × \(metadata.pixelHeight) · "
                + ByteCountFormatter.string(
                    fromByteCount: metadata.byteCount,
                    countStyle: .file
                )
        }
    }

    private var usageHint: String {
        switch item.content {
        case .text: "文字可选择并复制"
        case .image: "图片按原始比例完整显示"
        }
    }

    private var copyButtonIsDisabled: Bool {
        guard case .image = item.content else { return false }
        return isLoadingImage || imageLoadFailed
    }

    private func loadImageIfNeeded() async {
        guard case .image = item.content else { return }
        isLoadingImage = true
        imageLoadFailed = false
        let image = await model.detailImage(for: item)
        guard !Task.isCancelled else { return }
        detailImage = image
        imageLoadFailed = image == nil
        isLoadingImage = false
    }
}

private struct ClipboardHistoryTextDetailView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text
        textView.setAccessibilityLabel("完整复制文字")
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text else {
            return
        }
        textView.string = text
        textView.scrollToBeginningOfDocument(nil)
    }
}

private struct SharingHistoryContent: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let items = (model.sharedItems + model.receivedItems)
            .sorted { $0.createdAt > $1.createdAt }
        ContentSection(title: "全部分享记录") {
            if items.isEmpty {
                EmptyContentRow(systemImage: "clock", text: "还没有分享或接收记录")
            } else {
                ForEach(items) { item in
                    SharedItemRow(
                        item: item,
                        showsRemove: model.publicItems.contains(where: { $0.id == item.id }),
                        showsPublish: item.direction == .incoming
                            && !model.publicItems.contains(where: { $0.id == item.id })
                    )
                    if item.id != items.last?.id { Divider() }
                }
            }
        }
    }
}

struct ClipboardHistorySettingsSection: View {
    @ObservedObject var model: ClipboardHistoryFeatureModel

    var body: some View {
        Section("复制历史") {
            Toggle(
                "记录复制历史",
                isOn: Binding(
                    get: { model.isEnabled },
                    set: { model.setEnabled($0) }
                )
            )
            if let guidance = model.pasteboardAccessState.guidance {
                HStack(alignment: .firstTextBaseline) {
                    Text(guidance)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.pasteboardAccessState.needsSettingsButton {
                        Button("打开隐私与安全性") {
                            model.openPasteboardPrivacySettings()
                        }
                    }
                }
            }
            Stepper(
                value: Binding(
                    get: { model.maximumItemCount },
                    set: { model.setMaximumItemCount($0) }
                ),
                in: ClipboardHistoryFeatureModel.allowedMaximumItemCount
            ) {
                LabeledContent("最多保留", value: "\(model.maximumItemCount) 条")
            }
            .disabled(!model.isEnabled)
            Text("支持文字和图片。关闭后不再新增记录，已有记录继续保留；快捷翻译产生的临时复制会在隔离期内跳过。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
