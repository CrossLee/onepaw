import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

/// The two content kinds supported by OnePaw's macOS 14 recording backend.
/// The system sharing picker is presented before capture begins.
enum ScreenRecordingCaptureTarget: Sendable {
    case display
    case window

    fileprivate var pickerMode: ScreenCaptureSelectionMode {
        switch self {
        case .display:
            return .singleDisplay
        case .window:
            return .singleWindow
        }
    }
}

struct ScreenRecordingOptions: Sendable, Equatable {
    var capturesSystemAudio: Bool
    var excludesCurrentProcessAudio: Bool
    var showsCursor: Bool
    var framesPerSecond: Int
    var maximumDuration: TimeInterval
    var maximumFileSizeBytes: Int64
    var minimumFreeDiskSpaceBytes: Int64

    init(
        capturesSystemAudio: Bool = true,
        excludesCurrentProcessAudio: Bool = true,
        showsCursor: Bool = true,
        framesPerSecond: Int = 30,
        maximumDuration: TimeInterval = 2 * 60 * 60,
        maximumFileSizeBytes: Int64 = 10 * 1_024 * 1_024 * 1_024,
        minimumFreeDiskSpaceBytes: Int64 = 1 * 1_024 * 1_024 * 1_024
    ) {
        self.capturesSystemAudio = capturesSystemAudio
        self.excludesCurrentProcessAudio = excludesCurrentProcessAudio
        self.showsCursor = showsCursor
        self.framesPerSecond = framesPerSecond
        self.maximumDuration = maximumDuration
        self.maximumFileSizeBytes = maximumFileSizeBytes
        self.minimumFreeDiskSpaceBytes = minimumFreeDiskSpaceBytes
    }
}

enum ScreenRecordingState: Sendable, Equatable {
    case idle
    case choosingContent
    case preparingCapture
    case recording
    case stopping
    case completed(URL)
    case cancelled
    case failed(String)
}

enum ScreenRecordingBackendError: LocalizedError {
    case recordingAlreadyActive
    case notRecording
    case invalidFrameRate
    case invalidSafetyLimits
    case invalidCaptureGeometry
    case destinationMustBeMOV
    case destinationDirectoryUnavailable
    case destinationAlreadyExists
    case insufficientDiskSpace
    case cannotCreateWriter(String)
    case cannotAddVideoInput
    case cannotAddAudioInput
    case cannotAddStreamOutput(String)
    case captureStartFailed(String)
    case captureStopFailed(String)
    case noVideoFrames
    case writerFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .recordingAlreadyActive:
            return "已有录屏正在进行"
        case .notRecording:
            return "当前没有正在进行的录屏"
        case .invalidFrameRate:
            return "录屏帧率必须在 1 到 60 之间"
        case .invalidSafetyLimits:
            return "录屏时长、文件大小和磁盘空间限制必须大于零"
        case .invalidCaptureGeometry:
            return "系统返回的录屏画面尺寸无效"
        case .destinationMustBeMOV:
            return "录屏文件必须使用 .mov 扩展名"
        case .destinationDirectoryUnavailable:
            return "录屏保存目录不存在或不可写"
        case .destinationAlreadyExists:
            return "录屏保存位置已经存在文件"
        case .insufficientDiskSpace:
            return "可用磁盘空间不足，无法安全开始录屏"
        case .cannotCreateWriter(let message):
            return "无法创建录屏文件：\(message)"
        case .cannotAddVideoInput:
            return "无法创建录屏视频轨道"
        case .cannotAddAudioInput:
            return "无法创建系统音频轨道"
        case .cannotAddStreamOutput(let message):
            return "无法连接系统录屏输出：\(message)"
        case .captureStartFailed(let message):
            return "无法开始录屏：\(message)"
        case .captureStopFailed(let message):
            return "无法停止录屏：\(message)"
        case .noVideoFrames:
            return "录屏尚未生成有效画面"
        case .writerFailed(let message):
            return "录屏文件写入失败：\(message)"
        case .cancelled:
            return "录屏已取消"
        }
    }
}

/// Waits for an independently retained task while forwarding cancellation.
/// Keeping the cancellation handler outside the service method's scope lets
/// Swift 6 verify the task parameter independently from the actor-owned stored
/// reference while preserving immediate cancellation.
@MainActor
private func valueOfCancellableTask<Success: Sendable>(
    _ task: Task<Success, any Error>
) async throws -> Success {
    try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

/// Owns one ScreenCaptureKit stream and its MOV writer.
///
/// Call `start(target:destinationURL:options:)`, then retain this service until
/// either `stop()` or `cancel()` completes. All visible state changes happen on
/// the main actor, making the type straightforward to bridge into SwiftUI.
@MainActor
final class ScreenRecordingService {
    typealias StateHandler = @MainActor @Sendable (ScreenRecordingState) -> Void

    private(set) var state: ScreenRecordingState = .idle
    var stateDidChange: StateHandler?

    private var activePipeline: ScreenRecordingPipeline?
    private var pendingSelectionTask: Task<SCContentFilter, any Error>?
    private var pendingRegionSelectionTask: Task<ScreenRegionSelection, any Error>?
    private var pendingStartID: UUID?

    func start(
        target: ScreenRecordingCaptureTarget,
        destinationURL: URL,
        options: ScreenRecordingOptions = ScreenRecordingOptions()
    ) async throws {
        guard activePipeline == nil,
              pendingSelectionTask == nil,
              pendingRegionSelectionTask == nil,
              pendingStartID == nil else {
            throw ScreenRecordingBackendError.recordingAlreadyActive
        }
        guard (1...60).contains(options.framesPerSecond) else {
            throw ScreenRecordingBackendError.invalidFrameRate
        }
        guard options.maximumDuration.isFinite,
              options.maximumDuration > 0,
              options.maximumFileSizeBytes > 0,
              options.minimumFreeDiskSpaceBytes > 0 else {
            throw ScreenRecordingBackendError.invalidSafetyLimits
        }

        let outputURL = try Self.validatedDestination(
            destinationURL,
            minimumFreeDiskSpaceBytes: options.minimumFreeDiskSpaceBytes
        )
        let startID = UUID()
        pendingStartID = startID
        setState(.choosingContent)

        do {
            let selectionTask = Task { @MainActor in
                try await ScreenCaptureContentPicker.shared.selectContent(
                    target.pickerMode
                )
            }
            pendingSelectionTask = selectionTask
            let filter = try await valueOfCancellableTask(selectionTask)
            pendingSelectionTask = nil

            guard pendingStartID == startID else {
                throw ScreenRecordingBackendError.cancelled
            }
            try Task.checkCancellation()

            setState(.preparingCapture)
            try await startPipeline(
                filter: filter,
                sourceRect: nil,
                outputURL: outputURL,
                options: options,
                startID: startID
            )
        } catch is CancellationError {
            clearPendingStart(ifMatching: startID)
            try? FileManager.default.removeItem(at: outputURL)
            setState(.cancelled)
            throw ScreenRecordingBackendError.cancelled
        } catch ScreenCaptureKitBackendError.pickerCancelled {
            clearPendingStart(ifMatching: startID)
            try? FileManager.default.removeItem(at: outputURL)
            setState(.cancelled)
            throw ScreenRecordingBackendError.cancelled
        } catch ScreenRecordingBackendError.cancelled {
            clearPendingStart(ifMatching: startID)
            try? FileManager.default.removeItem(at: outputURL)
            setState(.cancelled)
            throw ScreenRecordingBackendError.cancelled
        } catch {
            clearPendingStart(ifMatching: startID)
            try? FileManager.default.removeItem(at: outputURL)
            setState(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Starts recording with a filter already resolved by the caller. This is
    /// used for "record current display", where OnePaw creates a display filter
    /// that excludes its own windows instead of presenting a second picker.
    func start(
        filter: SCContentFilter,
        destinationURL: URL,
        options: ScreenRecordingOptions = ScreenRecordingOptions()
    ) async throws {
        guard activePipeline == nil,
              pendingSelectionTask == nil,
              pendingRegionSelectionTask == nil,
              pendingStartID == nil else {
            throw ScreenRecordingBackendError.recordingAlreadyActive
        }
        guard (1...60).contains(options.framesPerSecond) else {
            throw ScreenRecordingBackendError.invalidFrameRate
        }
        guard options.maximumDuration.isFinite,
              options.maximumDuration > 0,
              options.maximumFileSizeBytes > 0,
              options.minimumFreeDiskSpaceBytes > 0 else {
            throw ScreenRecordingBackendError.invalidSafetyLimits
        }

        let outputURL = try Self.validatedDestination(
            destinationURL,
            minimumFreeDiskSpaceBytes: options.minimumFreeDiskSpaceBytes
        )
        let startID = UUID()
        pendingStartID = startID
        setState(.preparingCapture)

        do {
            try Task.checkCancellation()
            try await startPipeline(
                filter: filter,
                sourceRect: nil,
                outputURL: outputURL,
                options: options,
                startID: startID
            )
        } catch is CancellationError {
            clearPendingStart(ifMatching: startID)
            try? FileManager.default.removeItem(at: outputURL)
            setState(.cancelled)
            throw ScreenRecordingBackendError.cancelled
        } catch ScreenRecordingBackendError.cancelled {
            clearPendingStart(ifMatching: startID)
            try? FileManager.default.removeItem(at: outputURL)
            setState(.cancelled)
            throw ScreenRecordingBackendError.cancelled
        } catch {
            clearPendingStart(ifMatching: startID)
            try? FileManager.default.removeItem(at: outputURL)
            setState(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Lets the user drag a fixed region on any display, then records only
    /// that rectangle. The selection uses AppKit coordinates for interaction
    /// and carries a display-local, top-left source rectangle into
    /// ScreenCaptureKit without re-deriving it from the pointer position.
    func startRegion(
        destinationURL: URL,
        options: ScreenRecordingOptions = ScreenRecordingOptions()
    ) async throws {
        guard activePipeline == nil,
              pendingSelectionTask == nil,
              pendingRegionSelectionTask == nil,
              pendingStartID == nil else {
            throw ScreenRecordingBackendError.recordingAlreadyActive
        }
        guard (1...60).contains(options.framesPerSecond) else {
            throw ScreenRecordingBackendError.invalidFrameRate
        }
        guard options.maximumDuration.isFinite,
              options.maximumDuration > 0,
              options.maximumFileSizeBytes > 0,
              options.minimumFreeDiskSpaceBytes > 0 else {
            throw ScreenRecordingBackendError.invalidSafetyLimits
        }

        let outputURL = try Self.validatedDestination(
            destinationURL,
            minimumFreeDiskSpaceBytes: options.minimumFreeDiskSpaceBytes
        )
        let startID = UUID()
        pendingStartID = startID
        setState(.choosingContent)

        do {
            let selectionTask = Task { @MainActor in
                try await ScreenRegionSelectionCoordinator.shared.selectRegion(
                    purpose: .screenRecording
                )
            }
            pendingRegionSelectionTask = selectionTask
            let selection = try await valueOfCancellableTask(selectionTask)
            pendingRegionSelectionTask = nil

            guard pendingStartID == startID else {
                throw ScreenRecordingBackendError.cancelled
            }
            try Task.checkCancellation()

            let filter = try await ScreenCaptureKitScreenshotBackend.contentFilter(
                forDisplayID: selection.displayID
            )
            guard pendingStartID == startID else {
                throw ScreenRecordingBackendError.cancelled
            }
            try Task.checkCancellation()

            setState(.preparingCapture)
            try await startPipeline(
                filter: filter,
                sourceRect: selection.sourceRect,
                outputURL: outputURL,
                options: options,
                startID: startID
            )
        } catch is CancellationError {
            clearPendingStart(ifMatching: startID)
            try? FileManager.default.removeItem(at: outputURL)
            setState(.cancelled)
            throw ScreenRecordingBackendError.cancelled
        } catch ScreenRegionSelectionError.cancelled {
            clearPendingStart(ifMatching: startID)
            try? FileManager.default.removeItem(at: outputURL)
            setState(.cancelled)
            throw ScreenRecordingBackendError.cancelled
        } catch ScreenRecordingBackendError.cancelled {
            clearPendingStart(ifMatching: startID)
            try? FileManager.default.removeItem(at: outputURL)
            setState(.cancelled)
            throw ScreenRecordingBackendError.cancelled
        } catch {
            clearPendingStart(ifMatching: startID)
            try? FileManager.default.removeItem(at: outputURL)
            setState(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Stops capture, drains the sample queue, finalizes the MOV, and returns
    /// its URL. A failed finalization removes the incomplete output.
    func stop() async throws -> URL {
        guard state == .recording, let pipeline = activePipeline else {
            throw ScreenRecordingBackendError.notRecording
        }

        setState(.stopping)
        pipeline.beginEnding()

        do {
            try await pipeline.stopCapture()
            let outputURL = try await pipeline.finishWriting()
            activePipeline = nil
            setState(.completed(outputURL))
            return outputURL
        } catch {
            activePipeline = nil
            pipeline.cancelWritingAndDeleteOutput()
            setState(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Stops capture without producing a file. Safe to call more than once.
    func cancel() async {
        guard state != .stopping else { return }

        guard let pipeline = activePipeline else {
            if state == .choosingContent {
                pendingStartID = nil
                pendingSelectionTask?.cancel()
                pendingSelectionTask = nil
                pendingRegionSelectionTask?.cancel()
                pendingRegionSelectionTask = nil
                setState(.cancelled)
            }
            return
        }

        setState(.stopping)
        pipeline.beginEnding()
        try? await pipeline.stopCapture()
        pipeline.cancelWritingAndDeleteOutput()
        activePipeline = nil
        setState(.cancelled)
    }

    private func handleTerminationIfActive(
        _ pipeline: ScreenRecordingPipeline,
        termination: ScreenRecordingPipelineTermination
    ) async {
        guard activePipeline === pipeline, state == .recording else { return }

        setState(.stopping)
        pipeline.beginEnding()

        switch termination {
        case .failed(let message):
            try? await pipeline.stopCapture()
            pipeline.cancelWritingAndDeleteOutput()
            activePipeline = nil
            setState(.failed(message))

        case .userOrSystemStopped, .safetyLimitReached:
            if termination == .safetyLimitReached {
                try? await pipeline.stopCapture()
            }
            do {
                let outputURL = try await pipeline.finishWriting()
                activePipeline = nil
                setState(.completed(outputURL))
            } catch {
                pipeline.cancelWritingAndDeleteOutput()
                activePipeline = nil
                setState(.failed(error.localizedDescription))
            }
        }
    }

    private func setState(_ newState: ScreenRecordingState) {
        state = newState
        stateDidChange?(newState)
    }

    private func startPipeline(
        filter: SCContentFilter,
        sourceRect: CGRect?,
        outputURL: URL,
        options: ScreenRecordingOptions,
        startID: UUID
    ) async throws {
        let pipeline = try ScreenRecordingPipeline(
            filter: filter,
            sourceRect: sourceRect,
            outputURL: outputURL,
            options: options
        ) { [weak self] pipeline, termination in
            Task { @MainActor [weak self, weak pipeline] in
                guard let self, let pipeline else { return }
                await self.handleTerminationIfActive(
                    pipeline,
                    termination: termination
                )
            }
        }

        activePipeline = pipeline
        do {
            try await pipeline.startCapture()
            try Task.checkCancellation()
            guard activePipeline === pipeline,
                  pendingStartID == startID else {
                throw ScreenRecordingBackendError.cancelled
            }
        } catch {
            if activePipeline === pipeline {
                activePipeline = nil
                pipeline.beginEnding()
                try? await pipeline.stopCapture()
                pipeline.cancelWritingAndDeleteOutput()
            }
            throw error
        }

        pendingStartID = nil
        setState(.recording)
    }

    private func clearPendingStart(ifMatching startID: UUID) {
        guard pendingStartID == startID else { return }
        pendingStartID = nil
        pendingSelectionTask = nil
        pendingRegionSelectionTask = nil
    }

    private static func validatedDestination(
        _ url: URL,
        minimumFreeDiskSpaceBytes: Int64
    ) throws -> URL {
        guard url.isFileURL, url.pathExtension.lowercased() == "mov" else {
            throw ScreenRecordingBackendError.destinationMustBeMOV
        }

        let standardizedURL = url.standardizedFileURL
        let directoryURL = standardizedURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directoryURL.path,
            isDirectory: &isDirectory
        ),
        isDirectory.boolValue,
        FileManager.default.isWritableFile(atPath: directoryURL.path) else {
            throw ScreenRecordingBackendError.destinationDirectoryUnavailable
        }
        guard !FileManager.default.fileExists(atPath: standardizedURL.path) else {
            throw ScreenRecordingBackendError.destinationAlreadyExists
        }
        if let capacity = try? directoryURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage,
        capacity < minimumFreeDiskSpaceBytes {
            throw ScreenRecordingBackendError.insufficientDiskSpace
        }
        return standardizedURL
    }
}

private enum ScreenRecordingPipelineTermination: Sendable, Equatable {
    case failed(String)
    case userOrSystemStopped
    case safetyLimitReached
}

private final class ScreenRecordingPipeline: NSObject, @unchecked Sendable,
    SCStreamDelegate
{
    typealias TerminationHandler = @Sendable (
        ScreenRecordingPipeline,
        ScreenRecordingPipelineTermination
    ) -> Void

    let outputURL: URL

    private var stream: SCStream?
    private let sampleWriter: ScreenRecordingSampleWriter
    private let terminationHandler: TerminationHandler
    private let stateLock = NSLock()
    private var isEnding = false

    init(
        filter: SCContentFilter,
        sourceRect: CGRect?,
        outputURL: URL,
        options: ScreenRecordingOptions,
        terminationHandler: @escaping TerminationHandler
    ) throws {
        let geometry = try Self.captureGeometry(
            for: filter,
            sourceRect: sourceRect
        )
        let configuration = Self.streamConfiguration(
            geometry: geometry,
            options: options
        )
        let sampleWriter = try ScreenRecordingSampleWriter(
            outputURL: outputURL,
            dimensions: geometry.dimensions,
            options: options
        )

        self.outputURL = outputURL
        self.sampleWriter = sampleWriter
        self.terminationHandler = terminationHandler
        super.init()

        let configuredStream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: self
        )
        stream = configuredStream
        sampleWriter.terminationHandler = { [weak self] termination in
            self?.reportTerminationIfNeeded(termination)
        }

        do {
            try configuredStream.addStreamOutput(
                sampleWriter,
                type: .screen,
                sampleHandlerQueue: sampleWriter.sampleQueue
            )
            if options.capturesSystemAudio {
                try configuredStream.addStreamOutput(
                    sampleWriter,
                    type: .audio,
                    sampleHandlerQueue: sampleWriter.sampleQueue
                )
            }
        } catch {
            sampleWriter.cancelWritingAndDeleteOutput()
            throw ScreenRecordingBackendError.cannotAddStreamOutput(
                error.localizedDescription
            )
        }
    }

    func beginEnding() {
        stateLock.lock()
        isEnding = true
        stateLock.unlock()
    }

    func startCapture() async throws {
        guard let stream else {
            throw ScreenRecordingBackendError.captureStartFailed(
                "录屏流尚未初始化"
            )
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            stream.startCapture { error in
                if let error {
                    continuation.resume(
                        throwing: ScreenRecordingBackendError.captureStartFailed(
                            error.localizedDescription
                        )
                    )
                } else {
                    self.sampleWriter.startSafetyMonitoring()
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func stopCapture() async throws {
        guard let stream else { return }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            stream.stopCapture { error in
                if let error {
                    let nsError = error as NSError
                    if Self.isAlreadyStoppedError(nsError) {
                        continuation.resume(returning: ())
                    } else {
                        continuation.resume(
                            throwing: ScreenRecordingBackendError.captureStopFailed(
                                error.localizedDescription
                            )
                        )
                    }
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func finishWriting() async throws -> URL {
        try await sampleWriter.finishWriting()
    }

    func cancelWritingAndDeleteOutput() {
        sampleWriter.cancelWritingAndDeleteOutput()
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let nsError = error as NSError
        if Self.isExternalStopError(nsError) {
            reportTerminationIfNeeded(.userOrSystemStopped)
        } else {
            reportTerminationIfNeeded(.failed(error.localizedDescription))
        }
    }

    private func reportTerminationIfNeeded(
        _ termination: ScreenRecordingPipelineTermination
    ) {
        stateLock.lock()
        let shouldReport = !isEnding
        isEnding = true
        stateLock.unlock()

        if shouldReport {
            terminationHandler(self, termination)
        }
    }

    private static func isExternalStopError(_ error: NSError) -> Bool {
        guard error.domain == SCStreamErrorDomain else { return false }
        // -3817 is userStopped on macOS 14; -3821 is systemStoppedStream on
        // macOS 15+. Raw values keep the macOS 14 deployment target clean.
        return error.code == -3_817 || error.code == -3_821
    }

    private static func isAlreadyStoppedError(_ error: NSError) -> Bool {
        guard error.domain == SCStreamErrorDomain else { return false }
        // attemptToStopStreamState, userStopped, failedToStopAudioCapture,
        // and systemStoppedStream all mean no more samples will arrive.
        return [-3_808, -3_817, -3_819, -3_821].contains(error.code)
    }

    private static func captureGeometry(
        for filter: SCContentFilter,
        sourceRect requestedSourceRect: CGRect?
    ) throws -> ScreenRecordingGeometry {
        let contentRect = filter.contentRect.standardized
        let scale = CGFloat(filter.pointPixelScale)

        guard contentRect.width.isFinite,
              contentRect.height.isFinite,
              contentRect.width > 0,
              contentRect.height > 0,
              scale.isFinite,
              scale > 0 else {
            throw ScreenRecordingBackendError.invalidCaptureGeometry
        }

        let normalizedSourceRect: CGRect?
        let captureSize: CGSize
        if let requestedSourceRect {
            guard requestedSourceRect.origin.x.isFinite,
                  requestedSourceRect.origin.y.isFinite,
                  requestedSourceRect.width.isFinite,
                  requestedSourceRect.height.isFinite else {
                throw ScreenRecordingBackendError.invalidCaptureGeometry
            }

            let displayBounds = CGRect(origin: .zero, size: contentRect.size)
            let clippedRect = requestedSourceRect.standardized.intersection(displayBounds)
            guard !clippedRect.isNull,
                  !clippedRect.isEmpty,
                  clippedRect.width > 0,
                  clippedRect.height > 0 else {
                throw ScreenRecordingBackendError.invalidCaptureGeometry
            }

            // Expand fractional point edges to native-pixel boundaries. This
            // matches still-region capture and prevents a selected edge from
            // being omitted before the bounded encoder downscale is applied.
            let minimumPixelX = (clippedRect.minX * scale).rounded(.down)
            let minimumPixelY = (clippedRect.minY * scale).rounded(.down)
            let maximumPixelX = min(
                (clippedRect.maxX * scale).rounded(.up),
                (contentRect.width * scale).rounded(.down)
            )
            let maximumPixelY = min(
                (clippedRect.maxY * scale).rounded(.up),
                (contentRect.height * scale).rounded(.down)
            )
            let nativeWidth = maximumPixelX - minimumPixelX
            let nativeHeight = maximumPixelY - minimumPixelY
            guard nativeWidth.isFinite,
                  nativeHeight.isFinite,
                  nativeWidth >= 1,
                  nativeHeight >= 1 else {
                throw ScreenRecordingBackendError.invalidCaptureGeometry
            }

            normalizedSourceRect = CGRect(
                x: minimumPixelX / scale,
                y: minimumPixelY / scale,
                width: nativeWidth / scale,
                height: nativeHeight / scale
            )
            captureSize = CGSize(width: nativeWidth, height: nativeHeight)
        } else {
            normalizedSourceRect = nil
            captureSize = CGSize(
                width: contentRect.width * scale,
                height: contentRect.height * scale
            )
        }

        let sourceWidth = captureSize.width
        let sourceHeight = captureSize.height

        guard sourceWidth.isFinite,
              sourceHeight.isFinite,
              sourceWidth > 0,
              sourceHeight > 0 else {
            throw ScreenRecordingBackendError.invalidCaptureGeometry
        }

        // H.264 is the most broadly playable MOV codec. Bound both the longest
        // edge and total pixels so a 5K/6K display cannot create an excessive
        // encoder/memory load. 3840 x 2160 is exactly 8,294,400 pixels.
        let maximumDimension = CGFloat(3_840)
        let maximumPixels = CGFloat(8_294_400)
        let sourcePixels = sourceWidth * sourceHeight
        guard sourcePixels.isFinite, sourcePixels > 0 else {
            throw ScreenRecordingBackendError.invalidCaptureGeometry
        }
        let downscale = min(
            1,
            maximumDimension / sourceWidth,
            maximumDimension / sourceHeight,
            sqrt(maximumPixels / sourcePixels)
        )
        let width = max(2, Int((sourceWidth * downscale).rounded(.down)) & ~1)
        let height = max(2, Int((sourceHeight * downscale).rounded(.down)) & ~1)
        return ScreenRecordingGeometry(
            sourceRect: normalizedSourceRect,
            dimensions: ScreenRecordingDimensions(width: width, height: height)
        )
    }

    private static func streamConfiguration(
        geometry: ScreenRecordingGeometry,
        options: ScreenRecordingOptions
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        if let sourceRect = geometry.sourceRect {
            configuration.sourceRect = sourceRect
        }
        configuration.width = geometry.dimensions.width
        configuration.height = geometry.dimensions.height
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(options.framesPerSecond)
        )
        // ScreenCaptureKit supplies encoder-ready bi-planar video-range YUV;
        // AVAssetWriter consumes each CMSampleBuffer directly and encodes H.264.
        // This avoids the 4-byte-per-pixel traffic of BGRA at 4K.
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.queueDepth = 5
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = options.showsCursor
        configuration.captureResolution = .best
        configuration.capturesAudio = options.capturesSystemAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = options.excludesCurrentProcessAudio
        return configuration
    }
}

private struct ScreenRecordingGeometry: Sendable {
    let sourceRect: CGRect?
    let dimensions: ScreenRecordingDimensions
}

private struct ScreenRecordingDimensions: Sendable {
    let width: Int
    let height: Int
}

private final class ScreenRecordingSampleWriter: NSObject, @unchecked Sendable,
    SCStreamOutput
{
    let sampleQueue = DispatchQueue(
        label: "com.cross.crosstool.screen-recording.samples",
        qos: .userInitiated
    )

    private let outputURL: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let frameDuration: CMTime
    private let maximumDuration: TimeInterval
    private let maximumFileSizeBytes: Int64
    private let minimumFreeDiskSpaceBytes: Int64
    var terminationHandler: (@Sendable (ScreenRecordingPipelineTermination) -> Void)?

    // These properties are confined to `sampleQueue`.
    private var sessionStartTime: CMTime?
    private var sessionStartUptime: TimeInterval?
    private var lastVideoPresentationTime: CMTime?
    private var monitoringStartUptime: TimeInterval?
    private var safetyTimer: DispatchSourceTimer?
    private var hasReportedTermination = false
    private var isFinishing = false

    init(
        outputURL: URL,
        dimensions: ScreenRecordingDimensions,
        options: ScreenRecordingOptions
    ) throws {
        self.outputURL = outputURL
        frameDuration = CMTime(
            value: 1,
            timescale: CMTimeScale(options.framesPerSecond)
        )
        maximumDuration = options.maximumDuration
        maximumFileSizeBytes = options.maximumFileSizeBytes
        minimumFreeDiskSpaceBytes = options.minimumFreeDiskSpaceBytes

        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw ScreenRecordingBackendError.cannotCreateWriter(
                error.localizedDescription
            )
        }

        let pixelsPerSecond = dimensions.width * dimensions.height
            * options.framesPerSecond
        let averageBitRate = min(
            45_000_000,
            max(6_000_000, pixelsPerSecond / 7)
        )
        let compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: averageBitRate,
            AVVideoExpectedSourceFrameRateKey: options.framesPerSecond,
            AVVideoMaxKeyFrameIntervalKey: options.framesPerSecond * 2,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: dimensions.width,
            AVVideoHeightKey: dimensions.height,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]
        videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings
        )
        videoInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput) else {
            throw ScreenRecordingBackendError.cannotAddVideoInput
        }
        writer.add(videoInput)

        if options.capturesSystemAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ]
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: audioSettings
            )
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw ScreenRecordingBackendError.cannotAddAudioInput
            }
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }

        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        super.init()
    }

    func startSafetyMonitoring() {
        sampleQueue.async { [self] in
            guard safetyTimer == nil, !isFinishing else { return }
            monitoringStartUptime = ProcessInfo.processInfo.systemUptime
            let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                self?.evaluateSafetyLimits()
            }
            safetyTimer = timer
            timer.activate()
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard !isFinishing,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        switch outputType {
        case .screen:
            appendVideo(sampleBuffer)
        case .audio:
            appendAudio(sampleBuffer)
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    func finishWriting() async throws -> URL {
        let stopUptime = ProcessInfo.processInfo.systemUptime
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<URL, any Error>) in
            sampleQueue.async { [self] in
                guard !isFinishing else {
                    continuation.resume(
                        throwing: ScreenRecordingBackendError.notRecording
                    )
                    return
                }
                isFinishing = true
                stopSafetyMonitoring()

                guard let sessionStartTime,
                      let sessionStartUptime else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: outputURL)
                    continuation.resume(
                        throwing: ScreenRecordingBackendError.noVideoFrames
                    )
                    return
                }

                // ScreenCaptureKit may emit `.idle` frames while the selected
                // content is unchanged. Those frames have no new IOSurface and
                // must not be appended. Explicitly ending the writer session at
                // the user's stop time preserves the full wall-clock duration,
                // including a completely static tail.
                let elapsed = max(0, stopUptime - sessionStartUptime)
                let wallClockEndTime = CMTimeAdd(
                    sessionStartTime,
                    CMTime(seconds: elapsed, preferredTimescale: 60_000)
                )
                let lastFrameEndTime = lastVideoPresentationTime.map {
                    CMTimeAdd($0, frameDuration)
                } ?? wallClockEndTime
                let endTime = CMTimeCompare(
                    wallClockEndTime,
                    lastFrameEndTime
                ) >= 0 ? wallClockEndTime : lastFrameEndTime
                writer.endSession(atSourceTime: endTime)
                videoInput.markAsFinished()
                audioInput?.markAsFinished()
                writer.finishWriting { [self] in
                    if writer.status == .completed {
                        continuation.resume(returning: outputURL)
                    } else {
                        let message = writer.error?.localizedDescription
                            ?? "未知写入错误"
                        try? FileManager.default.removeItem(at: outputURL)
                        continuation.resume(
                            throwing: ScreenRecordingBackendError.writerFailed(
                                message
                            )
                        )
                    }
                }
            }
        }
    }

    func cancelWritingAndDeleteOutput() {
        sampleQueue.async { [self] in
            guard !isFinishing else { return }
            isFinishing = true
            stopSafetyMonitoring()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
        }
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
              isCompleteScreenFrame(sampleBuffer) else {
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid else { return }

        if sessionStartTime == nil {
            guard writer.startWriting() else {
                reportWriterFailureIfNeeded()
                return
            }
            writer.startSession(atSourceTime: presentationTime)
            sessionStartTime = presentationTime
            sessionStartUptime = ProcessInfo.processInfo.systemUptime
        }

        guard writer.status == .writing else {
            reportWriterFailureIfNeeded()
            return
        }
        guard videoInput.isReadyForMoreMediaData else { return }
        if !videoInput.append(sampleBuffer) {
            reportWriterFailureIfNeeded()
        } else {
            lastVideoPresentationTime = presentationTime
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let audioInput,
              let sessionStartTime,
              writer.status == .writing else {
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid,
              CMTimeCompare(presentationTime, sessionStartTime) >= 0,
              audioInput.isReadyForMoreMediaData else {
            return
        }
        if !audioInput.append(sampleBuffer) {
            reportWriterFailureIfNeeded()
        }
    }

    private func isCompleteScreenFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let statusValue = attachments.first?[.status] as? Int,
        let status = SCFrameStatus(rawValue: statusValue) else {
            return true
        }
        return status == .complete
    }

    private func reportWriterFailureIfNeeded() {
        guard !hasReportedTermination else { return }
        hasReportedTermination = true
        let message = writer.error?.localizedDescription ?? "编码器停止写入"

        // The writer does not own its pipeline. SCStream delegate failures are
        // the authoritative route for lifecycle cleanup; here we cancel the
        // writer immediately so a later stop cannot publish a corrupt file.
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: outputURL)
        terminationHandler?(.failed(message))
    }

    private func evaluateSafetyLimits() {
        guard !isFinishing,
              !hasReportedTermination,
              let monitoringStartUptime else {
            return
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - monitoringStartUptime
        let fileSize = ((try? FileManager.default.attributesOfItem(
            atPath: outputURL.path
        )[.size]) as? NSNumber)?.int64Value ?? 0
        let directoryURL = outputURL.deletingLastPathComponent()
        let freeCapacity = try? directoryURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage

        guard elapsed >= maximumDuration
                || fileSize >= maximumFileSizeBytes
                || (freeCapacity.map { $0 < minimumFreeDiskSpaceBytes } ?? false)
        else {
            return
        }

        hasReportedTermination = true
        terminationHandler?(.safetyLimitReached)
    }

    private func stopSafetyMonitoring() {
        safetyTimer?.setEventHandler {}
        safetyTimer?.cancel()
        safetyTimer = nil
    }
}
