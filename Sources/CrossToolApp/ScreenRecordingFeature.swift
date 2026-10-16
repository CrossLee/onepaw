import AppKit
import CoreGraphics
import CrossToolCore
import Foundation
import SwiftUI

enum ScreenRecordingSource: String, CaseIterable, Identifiable, Sendable {
    case currentDisplay
    case region
    case window

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentDisplay: return "录制当前屏幕"
        case .region: return "录制选定区域"
        case .window: return "录制一个窗口"
        }
    }

    var summary: String {
        switch self {
        case .currentDisplay:
            return "录制鼠标所在屏幕，并从画面中排除一爪"
        case .region:
            return "拖拽框选一个固定区域，只录制框内画面"
        case .window:
            return "通过 macOS 系统选择器指定一个窗口"
        }
    }

    var systemImage: String {
        switch self {
        case .currentDisplay: return "display"
        case .region: return "viewfinder"
        case .window: return "macwindow"
        }
    }
}

extension ScreenRecordingSource {
    var shortcutCommand: GlobalShortcutCommand {
        switch self {
        case .currentDisplay: return .recordCurrentDisplay
        case .region: return .recordRegion
        case .window: return .recordWindow
        }
    }
}

extension GlobalShortcutCommand {
    var recordingSource: ScreenRecordingSource? {
        switch self {
        case .recordCurrentDisplay: return .currentDisplay
        case .recordRegion: return .region
        case .recordWindow: return .window
        case .stopRecording, .screenshotRegion, .screenshotWindow, .screenshotScreen,
             .screenshotDelayed, .screenshotFramed, .screenshotMultiWindow,
             .screenshotScrolling, .pickColor, .translateText,
             .formatClipboardJSON, .showMainWindow:
            return nil
        }
    }
}

enum ScreenRecordingFeatureState: Equatable {
    case idle
    case choosingSource
    case starting
    case recording
    case stopping
    case completed(URL)
    case cancelled
    case failed(String)
}

enum RecordingCompletionDirectoryOpenResult: Equatable {
    case skipped
    case opened
    case failed
}

/// Keeps the Finder side effect tied to one successful recording operation.
///
/// `ScreenRecordingService.stop()` publishes `.completed` before it returns
/// the completed URL, so the feature can observe the same completion twice.
/// Recording the attempt before invoking Finder makes the side effect
/// single-shot even when Finder reports failure or a duplicate callback is
/// delivered. Starting another operation resets both suppression and the
/// attempt marker.
struct RecordingCompletionDirectoryOpenGate {
    private var operationID: UUID?
    private var suppressesAutomaticOpen = false
    private var hasAttemptedAutomaticOpen = false

    mutating func beginOperation(_ operationID: UUID) {
        self.operationID = operationID
        suppressesAutomaticOpen = false
        hasAttemptedAutomaticOpen = false
    }

    mutating func suppressAutomaticOpen(for operationID: UUID?) {
        guard self.operationID == operationID, operationID != nil else { return }
        suppressesAutomaticOpen = true
    }

    mutating func resumeAutomaticOpen(for operationID: UUID?) {
        guard self.operationID == operationID, operationID != nil else { return }
        suppressesAutomaticOpen = false
    }

    mutating func openAfterSuccessfulCompletion(
        operationID: UUID,
        recordingsDirectory: URL,
        using opener: (URL) -> Bool
    ) -> RecordingCompletionDirectoryOpenResult {
        guard self.operationID == operationID,
              !suppressesAutomaticOpen,
              !hasAttemptedAutomaticOpen else {
            return .skipped
        }

        // Mark the attempt first. A failed Finder request must not make a
        // duplicate completion callback try again and unexpectedly activate it.
        hasAttemptedAutomaticOpen = true
        return opener(recordingsDirectory) ? .opened : .failed
    }
}

@MainActor
final class ScreenRecordingFeatureModel: ObservableObject {
    typealias RecordingDirectoryOpenHandler = (URL) -> Bool

    static let classroomShareLimitBytes = Int64(SharedContentStore.maximumUploadBytes)

    @Published var capturesSystemAudio = true
    @Published var showsCursor = true
    @Published private(set) var state: ScreenRecordingFeatureState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var latestRecording: URL?
    @Published private(set) var latestFileSizeBytes: Int64?
    @Published private(set) var statusMessage: String?
    @Published private(set) var latestRecordingDeletionError: String?
    @Published private(set) var activeSource: ScreenRecordingSource?

    let recordingsDirectory: URL
    let draftsDirectory: URL

    private let service: ScreenRecordingService
    private let recordingDirectoryOpenHandler: RecordingDirectoryOpenHandler
    private var activeDraftURL: URL?
    private var activeFinalURL: URL?
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Bool, Never>?
    private var elapsedTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    private var isFinalizing = false
    private var activeOperationID: UUID?
    private var activeRegionHiddenWindows: TemporarilyHiddenAppWindows?
    private var cancellationInProgress = false
    private var completionDirectoryOpenGate = RecordingCompletionDirectoryOpenGate()

    convenience init() {
        self.init(
            service: ScreenRecordingService(),
            recordingDirectoryOpenHandler: { directory in
                NSWorkspace.shared.open(directory)
            }
        )
    }

    init(
        service: ScreenRecordingService,
        recordingDirectoryOpenHandler: @escaping RecordingDirectoryOpenHandler = { directory in
            NSWorkspace.shared.open(directory)
        }
    ) {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("crosstool", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        let drafts = root.appendingPathComponent("Drafts", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: drafts,
            withIntermediateDirectories: true
        )

        self.service = service
        self.recordingDirectoryOpenHandler = recordingDirectoryOpenHandler
        self.recordingsDirectory = root
        self.draftsDirectory = drafts
        service.stateDidChange = { [weak self] newState in
            self?.handleServiceState(newState)
        }
        reloadLatestRecordingFromDisk()
    }

    var isBusy: Bool {
        if cancellationInProgress { return true }
        switch state {
        case .choosingSource, .starting, .recording, .stopping:
            return true
        case .idle, .completed, .cancelled, .failed:
            return false
        }
    }

    var isRecording: Bool {
        state == .recording
    }

    var canShareLatestRecording: Bool {
        guard latestRecording != nil, let latestFileSizeBytes else { return false }
        return latestFileSizeBytes <= Self.classroomShareLimitBytes
    }

    var canDeleteLatestRecording: Bool {
        latestRecording != nil && !isBusy
    }

    var elapsedText: String {
        Self.durationFormatter.string(from: elapsed) ?? "00:00"
    }

    var latestFileSizeText: String? {
        latestFileSizeBytes.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        }
    }

    func start(_ source: ScreenRecordingSource) {
        guard !isBusy,
              startTask == nil,
              stopTask == nil,
              activeOperationID == nil else { return }
        latestRecordingDeletionError = nil

        do {
            try prepareDestinations()
            try validateStartDiskSpace()
        } catch {
            state = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
            return
        }

        let operationID = UUID()
        activeOperationID = operationID
        completionDirectoryOpenGate.beginOperation(operationID)
        activeSource = source
        switch source {
        case .currentDisplay:
            state = .starting
            statusMessage = "正在准备录制鼠标所在屏幕…"
        case .region:
            state = .choosingSource
            statusMessage = "请拖拽框选要录制的固定区域"
        case .window:
            state = .choosingSource
            statusMessage = "请在系统选择器中选择要录制的窗口"
        }
        let options = ScreenRecordingOptions(
            capturesSystemAudio: capturesSystemAudio,
            excludesCurrentProcessAudio: true,
            showsCursor: showsCursor,
            framesPerSecond: 30,
            maximumDuration: 2 * 60 * 60,
            maximumFileSizeBytes: 10 * 1_024 * 1_024 * 1_024,
            minimumFreeDiskSpaceBytes: 1 * 1_024 * 1_024 * 1_024
        )

        startTask = Task { @MainActor [weak self] in
            guard let self, let draftURL = self.activeDraftURL else { return }

            do {
                switch source {
                case .currentDisplay:
                    let displayID = try Self.displayIDUnderMouse()
                    let filter = try await ScreenCaptureKitScreenshotBackend.contentFilter(
                        forDisplayID: displayID
                    )
                    try Task.checkCancellation()
                    try await self.service.start(
                        filter: filter,
                        destinationURL: draftURL,
                        options: options
                    )
                case .region:
                    let hiddenWindows = TemporarilyHiddenAppWindows()
                    self.activeRegionHiddenWindows = hiddenWindows
                    // Let WindowServer expose the content behind OnePaw before
                    // the full-screen selection overlays are presented.
                    try await Task.sleep(for: .milliseconds(120))
                    try await self.service.startRegion(
                        destinationURL: draftURL,
                        options: options
                    )
                    // The recording filter excludes OnePaw. Restore only the
                    // detached image pins so the user can reference them while
                    // interacting with the selected app; keep the main window
                    // hidden until recording reaches a terminal state.
                    hiddenWindows.restorePinnedScreenshotWindows()
                    // The captured filter excludes OnePaw, but keeping the App
                    // active would still route keys and clicks away from the
                    // selected application underneath the hidden windows.
                    NSApp.deactivate()
                case .window:
                    try await self.service.start(
                        target: .window,
                        destinationURL: draftURL,
                        options: options
                    )
                }
                guard self.activeOperationID == operationID else { return }
                if self.cancellationInProgress {
                    await self.service.cancel()
                    return
                }
                self.startTask = nil
            } catch ScreenRecordingBackendError.cancelled {
                guard self.activeOperationID == operationID,
                      !self.cancellationInProgress else {
                    return
                }
                self.cleanActiveDraft()
                self.activeOperationID = nil
                self.startTask = nil
                if self.state != .cancelled {
                    self.state = .cancelled
                    self.statusMessage = "已取消录屏"
                }
            } catch is CancellationError {
                guard self.activeOperationID == operationID,
                      !self.cancellationInProgress else {
                    return
                }
                await self.service.cancel()
                self.cleanActiveDraft()
                self.activeOperationID = nil
                self.startTask = nil
                self.state = .cancelled
                self.statusMessage = "已取消录屏"
            } catch {
                guard self.activeOperationID == operationID,
                      !self.cancellationInProgress else {
                    return
                }
                self.cleanActiveDraft()
                self.activeOperationID = nil
                self.startTask = nil
                self.state = .failed(error.localizedDescription)
                self.statusMessage = "录屏失败：\(error.localizedDescription)"
            }
        }
    }

    func stop() {
        _ = beginStopIfNeeded()
    }

    func cancel() {
        guard isBusy else { return }
        Task { @MainActor [weak self] in
            await self?.cancelCurrentOperation()
        }
    }

    func playLatestRecording() {
        guard let latestRecording else { return }
        NSWorkspace.shared.open(latestRecording)
    }

    func revealLatestRecording() {
        guard let latestRecording else { return }
        NSWorkspace.shared.activateFileViewerSelecting([latestRecording])
    }

    func openRecordingsDirectory() {
        NSWorkspace.shared.open(recordingsDirectory)
    }

    @discardableResult
    func deleteLatestRecording(expectedURL: URL) -> Bool {
        guard !isBusy else {
            latestRecordingDeletionError = "正在录屏或保存成片，请完成后再删除"
            return false
        }
        guard let latestRecording,
              latestRecording.standardizedFileURL == expectedURL.standardizedFileURL else {
            latestRecordingDeletionError = "最近录屏已经更新，请重新选择后删除"
            return false
        }

        do {
            try ManagedRecordingDeletion.delete(
                recordingURL: latestRecording,
                recordingsDirectory: recordingsDirectory
            )
            reloadLatestRecordingFromDisk()
            latestRecordingDeletionError = nil
            if case .completed(let completedURL) = state,
               completedURL.standardizedFileURL == expectedURL.standardizedFileURL {
                state = .idle
            }
            statusMessage = "录屏文件已从本机删除"
            return true
        } catch ManagedRecordingDeletionError.fileNotFound {
            reloadLatestRecordingFromDisk()
            latestRecordingDeletionError = nil
            statusMessage = "录屏文件已不存在，最近录屏已刷新"
            return true
        } catch {
            latestRecordingDeletionError = "删除失败，文件和记录均已保留：\(error.localizedDescription)"
            return false
        }
    }

    /// Used by the app delegate before replying to a Cmd-Q request.
    func prepareForApplicationTermination() async -> Bool {
        // Completing a recording is part of safe termination, but activating
        // Finder while the app is quitting is surprising and can delay quit.
        let operationID = activeOperationID
        completionDirectoryOpenGate.suppressAutomaticOpen(for: operationID)
        if stopTask != nil {
            return await finishTerminationWait(for: operationID)
        }

        switch state {
        case .choosingSource, .starting:
            await cancelCurrentOperation()
            return true
        case .recording:
            guard beginStopIfNeeded() != nil else { return false }
            return await finishTerminationWait(for: operationID)
        case .stopping:
            return await finishTerminationWait(for: operationID)
        case .idle, .completed, .cancelled:
            return true
        case .failed:
            return false
        }
    }

    private func finishTerminationWait(for operationID: UUID?) async -> Bool {
        let canTerminate = await waitForRecordingFinalizationDuringTermination()
        if !canTerminate {
            // AppKit will cancel this quit request. If the system finishes the
            // recording later, restore the normal post-save Finder behavior.
            completionDirectoryOpenGate.resumeAutomaticOpen(for: operationID)
        }
        return canTerminate
    }

    private func waitForRecordingFinalizationDuringTermination() async -> Bool {
        for _ in 0..<300 {
            if stopTask == nil {
                switch state {
                case .idle, .completed, .cancelled:
                    return true
                case .failed:
                    return false
                case .choosingSource, .starting, .recording, .stopping:
                    break
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        // Re-check after the final sleep so a save that completes on the
        // timeout boundary is not incorrectly treated as still running.
        switch state {
        case .idle, .completed, .cancelled:
            return true
        case .failed:
            return false
        case .choosingSource, .starting, .recording, .stopping:
            break
        }

        statusMessage = "录屏仍在保存，请稍后再退出"
        return false
    }

    private func beginStopIfNeeded() -> Task<Bool, Never>? {
        if let stopTask { return stopTask }
        guard state == .recording else { return nil }

        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            defer { self.stopTask = nil }
            return await self.stopAndFinalize()
        }
        stopTask = task
        return task
    }

    private func stopAndFinalize() async -> Bool {
        guard state == .recording else {
            if case .completed = state { return true }
            return false
        }

        do {
            let draftURL = try await service.stop()
            return finalizeCompletedDraft(at: draftURL)
        } catch {
            if case .completed = state {
                return true
            }
            restoreRegionWindows()
            activeSource = nil
            statusMessage = "停止录屏失败：\(error.localizedDescription)"
            state = .failed(error.localizedDescription)
            return false
        }
    }

    private func cancelCurrentOperation() async {
        guard !cancellationInProgress else { return }
        cancellationInProgress = true
        let operationID = activeOperationID
        let task = startTask
        state = .stopping
        statusMessage = "正在取消录屏…"
        task?.cancel()
        await service.cancel()
        if let task {
            await task.value
        }
        guard activeOperationID == operationID else {
            cancellationInProgress = false
            return
        }
        startTask = nil
        stopElapsedTimer()
        cleanActiveDraft()
        activeOperationID = nil
        cancellationInProgress = false
        state = .cancelled
        statusMessage = "已取消录屏，未保存文件"
    }

    private func handleServiceState(_ newState: ScreenRecordingState) {
        switch newState {
        case .idle:
            if !isBusy { state = .idle }
        case .choosingContent:
            state = .choosingSource
            statusMessage = activeSource == .region
                ? "请拖拽框选要录制的固定区域"
                : "请在系统选择器中选择要录制的内容"
        case .preparingCapture:
            state = .starting
            statusMessage = "正在启动录屏…"
        case .recording:
            state = .recording
            recordingStartedAt = Date()
            elapsed = 0
            statusMessage = capturesSystemAudio
                ? "正在录制屏幕和系统声音"
                : "正在录制屏幕"
            startElapsedTimer()
        case .stopping:
            state = .stopping
            statusMessage = "正在完成 MOV 文件，请稍候…"
            stopElapsedTimer(updateOneLastTime: true)
        case .completed(let draftURL):
            _ = finalizeCompletedDraft(at: draftURL)
        case .cancelled:
            guard !cancellationInProgress else { return }
            stopElapsedTimer()
            cleanActiveDraft()
            activeOperationID = nil
            startTask = nil
            state = .cancelled
            statusMessage = "已取消录屏"
        case .failed(let message):
            stopElapsedTimer()
            cleanActiveDraft()
            activeOperationID = nil
            startTask = nil
            state = .failed(message)
            statusMessage = "录屏失败：\(message)"
        }
    }

    @discardableResult
    private func finalizeCompletedDraft(at draftURL: URL) -> Bool {
        if case .completed(let existingURL) = state,
           existingURL == latestRecording {
            return true
        }
        guard !isFinalizing,
              let expectedDraftURL = activeDraftURL,
              let finalURL = activeFinalURL,
              let operationID = activeOperationID,
              expectedDraftURL.standardizedFileURL == draftURL.standardizedFileURL else {
            return false
        }

        isFinalizing = true
        defer { isFinalizing = false }
        stopElapsedTimer(updateOneLastTime: true)

        do {
            try FileManager.default.moveItem(at: draftURL, to: finalURL)
            let values = try? finalURL.resourceValues(forKeys: [.fileSizeKey])
            latestRecording = finalURL
            latestFileSizeBytes = values?.fileSize.map(Int64.init)
            latestRecordingDeletionError = nil
            activeDraftURL = nil
            activeFinalURL = nil
            activeOperationID = nil
            activeSource = nil
            startTask = nil
            restoreRegionWindows()
            state = .completed(finalURL)
            let openResult = completionDirectoryOpenGate.openAfterSuccessfulCompletion(
                operationID: operationID,
                recordingsDirectory: recordingsDirectory,
                using: recordingDirectoryOpenHandler
            )
            switch openResult {
            case .opened:
                statusMessage = "录屏已保存，已打开录屏文件夹；不会自动加入课堂共享"
            case .failed:
                statusMessage = "录屏已保存，但无法自动打开录屏文件夹"
            case .skipped:
                statusMessage = "录屏已保存到本地，不会自动加入课堂共享"
            }
            return true
        } catch {
            // A finalized MOV is valuable even if the final rename failed.
            // Keep it in Drafts so the user can recover it manually.
            activeDraftURL = nil
            activeFinalURL = nil
            activeOperationID = nil
            activeSource = nil
            startTask = nil
            restoreRegionWindows()
            state = .failed(error.localizedDescription)
            statusMessage = "录屏已完成，但移动到正式目录失败；文件保留在 Drafts：\(error.localizedDescription)"
            return false
        }
    }

    private func prepareDestinations() throws {
        try FileManager.default.createDirectory(
            at: draftsDirectory,
            withIntermediateDirectories: true
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stem = "录屏 \(formatter.string(from: Date())) \(UUID().uuidString.prefix(8).lowercased())"
        activeDraftURL = draftsDirectory
            .appendingPathComponent("\(stem).partial.mov", isDirectory: false)
        activeFinalURL = recordingsDirectory
            .appendingPathComponent("\(stem).mov", isDirectory: false)
    }

    /// Restores the most recent completed MOV after relaunch and advances to
    /// the next recording after a deletion. Drafts, links and nested content
    /// never enter the recent-recording UI.
    private func reloadLatestRecordingFromDisk() {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .fileSizeKey
        ]
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []

        let newest = candidates.compactMap { url -> (URL, Date, Int64)? in
            guard url.pathExtension.lowercased() == "mov",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                return nil
            }
            return (
                url.standardizedFileURL,
                values.contentModificationDate ?? .distantPast,
                Int64(values.fileSize ?? 0)
            )
        }
        .max { lhs, rhs in lhs.1 < rhs.1 }

        latestRecording = newest?.0
        latestFileSizeBytes = newest?.2
    }

    private func validateStartDiskSpace() throws {
        let values = try recordingsDirectory.resourceValues(
            forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ]
        )
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init)
        guard let available,
              available >= 2 * 1_024 * 1_024 * 1_024 else {
            cleanActiveDraft()
            throw ScreenRecordingFeatureError.insufficientStartDiskSpace
        }
    }

    private func cleanActiveDraft() {
        if let activeDraftURL,
           activeDraftURL.deletingLastPathComponent().standardizedFileURL
            == draftsDirectory.standardizedFileURL {
            try? FileManager.default.removeItem(at: activeDraftURL)
        }
        activeDraftURL = nil
        activeFinalURL = nil
        activeSource = nil
        restoreRegionWindows()
    }

    private func restoreRegionWindows() {
        guard let hiddenWindows = activeRegionHiddenWindows else { return }
        activeRegionHiddenWindows = nil
        hiddenWindows.restore()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, let startedAt = self.recordingStartedAt else {
                    continue
                }
                self.elapsed = max(0, Date().timeIntervalSince(startedAt))
            }
        }
    }

    private func stopElapsedTimer(updateOneLastTime: Bool = false) {
        if updateOneLastTime, let recordingStartedAt {
            elapsed = max(elapsed, Date().timeIntervalSince(recordingStartedAt))
        }
        elapsedTask?.cancel()
        elapsedTask = nil
        recordingStartedAt = nil
    }

    private static func displayIDUnderMouse() throws -> CGDirectDisplayID {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(mouseLocation, $0.frame, false)
        }),
        let screenNumber = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else {
            throw ScreenCaptureKitBackendError.displayUnavailable
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = [.pad]
        return formatter
    }()
}

private enum ScreenRecordingFeatureError: LocalizedError {
    case insufficientStartDiskSpace

    var errorDescription: String? {
        switch self {
        case .insufficientStartDiskSpace:
            return "可用磁盘空间不足 2 GB，无法安全开始录屏"
        }
    }
}

@MainActor
struct ScreenRecordingPage: View {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject private var model: ScreenRecordingFeatureModel
    @State private var recordingPendingDeletion: URL?
    private let shareRecording: (URL) -> Void
    private let onRecordingDeleted: (URL) -> Void

    init(
        model: ScreenRecordingFeatureModel,
        shareRecording: @escaping (URL) -> Void,
        onRecordingDeleted: @escaping (URL) -> Void = { _ in }
    ) {
        self.model = model
        self.shareRecording = shareRecording
        self.onRecordingDeleted = onRecordingDeleted
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "录屏",
                    subtitle: "录制整个屏幕、框选固定区域或指定窗口；完成后先保存在本机"
                )

                if !appModel.hasScreenCapturePermission {
                    recordingPermissionBanner
                }

                if model.isBusy {
                    activeRecordingCard
                } else {
                    sourceCards
                    optionCard
                }

                latestRecordingCard
            }
            .padding(30)
        }
        .confirmationDialog(
            "删除这段录屏？",
            isPresented: Binding(
                get: { recordingPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        recordingPendingDeletion = nil
                    }
                }
            ),
            presenting: recordingPendingDeletion
        ) { recording in
            Button("删除录屏文件", role: .destructive) {
                if model.deleteLatestRecording(expectedURL: recording) {
                    onRecordingDeleted(recording)
                }
                recordingPendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                recordingPendingDeletion = nil
            }
        } message: { recording in
            Text("将永久删除“\(recording.lastPathComponent)”。若已加入课堂共享，也会同步移除共享项。此操作无法撤销。")
        }
    }

    private var sourceCards: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 230), spacing: 16)],
            spacing: 16
        ) {
            ForEach(ScreenRecordingSource.allCases) { source in
                Button {
                    appModel.startRecording(source)
                } label: {
                    HStack(spacing: 15) {
                        Image(systemName: source.systemImage)
                            .font(.system(size: 25, weight: .medium))
                            .foregroundStyle(Color.crossToolAccent)
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(source.title)
                                .font(.headline)
                            Text(source.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 8) {
                            Text(appModel.shortcutLabel(for: source.shortcutCommand))
                                .font(.system(.caption, design: .monospaced, weight: .semibold))
                                .foregroundStyle(Color.crossToolAccent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.crossToolAccent.opacity(0.09))
                                .clipShape(Capsule())
                            Image(systemName: "record.circle")
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, minHeight: 102)
                    .background(.background)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.crossToolBorder, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var recordingPermissionBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 22))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("录屏需要屏幕与系统音频录制权限")
                    .font(.headline)
                Text("授权后请完全退出并重新打开一爪；取色功能不需要此权限。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("申请权限") {
                appModel.requestScreenCapturePermission()
            }
            .buttonStyle(.borderedProminent)
            Button("打开系统设置") {
                appModel.openScreenCaptureSettings()
            }
        }
        .padding(16)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        }
    }

    private var optionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("录制选项")
                .font(.headline)
            Toggle("录制系统声音", isOn: $model.capturesSystemAudio)
            Toggle("显示鼠标指针", isOn: $model.showsCursor)
            Text("首版暂不录制麦克风；录屏最长 2 小时或 10 GB，并会预留磁盘安全空间。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.crossToolBorder, lineWidth: 1)
        }
    }

    private var activeRecordingCard: some View {
        HStack(spacing: 18) {
            Circle()
                .fill(model.isRecording ? Color.red : Color.orange)
                .frame(width: 13, height: 13)
                .shadow(
                    color: model.isRecording ? Color.red.opacity(0.35) : .clear,
                    radius: 5
                )
            VStack(alignment: .leading, spacing: 5) {
                Text(activeTitle)
                    .font(.headline)
                Text(model.statusMessage ?? "正在处理…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRecording {
                Text(model.elapsedText)
                    .font(.system(.title3, design: .monospaced, weight: .semibold))
                Button {
                    model.stop()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "stop.fill")
                        Text("停止录屏")
                        if let shortcut = activeStopShortcutLabel {
                            Text(shortcut)
                                .font(.system(.caption, design: .monospaced, weight: .semibold))
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else if model.state != .stopping {
                Button("取消", role: .destructive) {
                    model.cancel()
                }
            }
        }
        .padding(20)
        .background(Color.red.opacity(model.isRecording ? 0.055 : 0.025))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.red.opacity(0.18), lineWidth: 1)
        }
    }

    private var latestRecordingCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("最近录屏")
                        .font(.headline)
                    Text("录屏默认只保存在本机，不会自动公开给学生")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("打开录屏文件夹", systemImage: "folder") {
                    model.openRecordingsDirectory()
                }
            }

            if let recording = model.latestRecording {
                Divider()
                HStack(spacing: 12) {
                    Image(systemName: "film")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.crossToolAccent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(recording.lastPathComponent)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(model.latestFileSizeText ?? "大小未知")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("播放", systemImage: "play.fill") {
                        model.playLatestRecording()
                    }
                    Button("在 Finder 中显示", systemImage: "folder") {
                        model.revealLatestRecording()
                    }
                    Button("删除", systemImage: "trash", role: .destructive) {
                        recordingPendingDeletion = recording
                    }
                    .disabled(!model.canDeleteLatestRecording)
                    Button("加入课堂共享", systemImage: "person.2") {
                        shareRecording(recording)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canShareLatestRecording)
                }
                if !model.canShareLatestRecording {
                    Text("该录屏超过 256 MB，当前课堂共享通道不会读取或公开它。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let deletionError = model.latestRecordingDeletionError {
                    Label(deletionError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "film")
                    Text(model.statusMessage ?? "完成录屏后会显示在这里")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            }
        }
        .padding(20)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.crossToolBorder, lineWidth: 1)
        }
    }

    private var activeTitle: String {
        switch model.state {
        case .choosingSource: return "正在选择录制内容"
        case .starting: return "正在准备录屏"
        case .recording: return "正在录屏"
        case .stopping: return "正在保存录屏"
        case .idle, .completed, .cancelled, .failed: return "录屏"
        }
    }

    private var activeStopShortcutLabel: String? {
        if let stopShortcut = appModel.configuredShortcutLabel(for: .stopRecording) {
            return stopShortcut
        }
        guard let source = model.activeSource else { return nil }
        return appModel.configuredShortcutLabel(for: source.shortcutCommand)
    }
}
