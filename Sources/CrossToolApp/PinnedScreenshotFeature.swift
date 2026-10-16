import AppKit
import CoreGraphics
import Foundation

enum PinnedScreenshotFeatureError: LocalizedError {
    case invalidImage
    case snapshotCreationFailed
    case noAvailableScreen
    case memoryBudgetExceeded(requiredBytes: Int, availableBytes: Int)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "无法读取要固定的截图"
        case .snapshotCreationFailed:
            return "无法生成贴图预览"
        case .noAvailableScreen:
            return "找不到可显示贴图的屏幕"
        case .memoryBudgetExceeded(let requiredBytes, let availableBytes):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .memory
            let required = formatter.string(fromByteCount: Int64(requiredBytes))
            let available = formatter.string(fromByteCount: Int64(max(0, availableBytes)))
            return "贴图占用空间不足（需要 \(required)，当前可用 \(available)），请先关闭一张贴图"
        }
    }
}

/// Pure geometry for creating and recovering a small pinned-image window.
struct PinnedScreenshotLayout {
    static let maximumInitialWidth: CGFloat = 520
    static let maximumInitialHeight: CGFloat = 420
    static let maximumVisibleFrameFraction: CGFloat = 0.40
    static let maximumZoomVisibleFrameFraction: CGFloat = 0.90
    static let minimumLongestSide: CGFloat = 120
    static let anchorGap: CGFloat = 14

    static func initialFrame(
        sourcePixelSize: CGSize,
        backingScaleFactor: CGFloat = 1,
        visibleFrame: CGRect,
        anchor: CGPoint
    ) -> CGRect {
        let visibleFrame = usableVisibleFrame(visibleFrame)
        guard visibleFrame.width > 0, visibleFrame.height > 0 else {
            return CGRect(origin: anchor, size: .zero)
        }

        let normalizedScale = backingScaleFactor.isFinite && backingScaleFactor > 0
            ? backingScaleFactor
            : 1
        let sourcePixels = usableSourceSize(sourcePixelSize)
        let sourceSize = CGSize(
            width: sourcePixels.width / normalizedScale,
            height: sourcePixels.height / normalizedScale
        )
        let maximumWidth = max(
            1,
            min(maximumInitialWidth, visibleFrame.width * maximumVisibleFrameFraction)
        )
        let maximumHeight = max(
            1,
            min(maximumInitialHeight, visibleFrame.height * maximumVisibleFrameFraction)
        )

        var scale = min(
            1,
            maximumWidth / sourceSize.width,
            maximumHeight / sourceSize.height
        )
        var size = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )

        let longestSide = max(size.width, size.height)
        let attainableMinimum = min(
            minimumLongestSide,
            max(maximumWidth, maximumHeight)
        )
        if longestSide > 0, longestSide < attainableMinimum {
            scale = min(
                attainableMinimum / longestSide,
                maximumWidth / size.width,
                maximumHeight / size.height
            )
            size.width *= scale
            size.height *= scale
        }

        let candidates = [
            CGPoint(
                x: anchor.x + anchorGap,
                y: anchor.y - size.height - anchorGap
            ),
            CGPoint(
                x: anchor.x - size.width - anchorGap,
                y: anchor.y - size.height - anchorGap
            ),
            CGPoint(
                x: anchor.x + anchorGap,
                y: anchor.y + anchorGap
            ),
            CGPoint(
                x: anchor.x - size.width - anchorGap,
                y: anchor.y + anchorGap
            ),
        ]

        var bestFrame: CGRect?
        var smallestAdjustmentSquared = CGFloat.infinity
        for origin in candidates {
            let proposed = CGRect(origin: origin, size: size)
            let adjusted = clamped(frame: proposed, to: visibleFrame)
            let dx = adjusted.minX - proposed.minX
            let dy = adjusted.minY - proposed.minY
            let adjustmentSquared = dx * dx + dy * dy
            if adjustmentSquared < smallestAdjustmentSquared {
                bestFrame = adjusted
                smallestAdjustmentSquared = adjustmentSquared
            }
        }

        return bestFrame ?? clamped(
            frame: CGRect(origin: anchor, size: size),
            to: visibleFrame
        )
    }

    /// Shrinks proportionally when necessary, then moves the whole frame into
    /// the supplied visible frame. Negative global display origins are valid.
    static func clamped(frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        let visibleFrame = usableVisibleFrame(visibleFrame)
        guard visibleFrame.width > 0, visibleFrame.height > 0 else {
            return .zero
        }

        let standardized = frame.standardized
        var size = CGSize(
            width: finitePositive(standardized.width),
            height: finitePositive(standardized.height)
        )
        if size.width == 0 || size.height == 0 {
            size = CGSize(width: 1, height: 1)
        }

        let scale = min(
            1,
            visibleFrame.width / size.width,
            visibleFrame.height / size.height
        )
        size.width *= scale
        size.height *= scale

        let proposedX = standardized.minX.isFinite
            ? standardized.minX
            : visibleFrame.minX
        let proposedY = standardized.minY.isFinite
            ? standardized.minY
            : visibleFrame.minY
        let x = min(
            max(proposedX, visibleFrame.minX),
            visibleFrame.maxX - size.width
        )
        let y = min(
            max(proposedY, visibleFrame.minY),
            visibleFrame.maxY - size.height
        )
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    static func minimumContentSize(for sourcePixelSize: CGSize) -> CGSize {
        let sourceSize = usableSourceSize(sourcePixelSize)
        if sourceSize.width >= sourceSize.height {
            return CGSize(
                width: minimumLongestSide,
                height: minimumLongestSide * sourceSize.height / sourceSize.width
            )
        }
        return CGSize(
            width: minimumLongestSide * sourceSize.width / sourceSize.height,
            height: minimumLongestSide
        )
    }

    static func maximumContentSize(for visibleFrame: CGRect) -> CGSize {
        let visibleFrame = usableVisibleFrame(visibleFrame)
        return CGSize(
            width: max(1, visibleFrame.width * maximumZoomVisibleFrameFraction),
            height: max(1, visibleFrame.height * maximumZoomVisibleFrameFraction)
        )
    }

    /// Resizes around a screen-space pointer so the pixel under the pointer
    /// stays stable until a display edge requires the window to move.
    static func zoomedFrame(
        frame: CGRect,
        around screenPoint: CGPoint,
        scaleFactor: CGFloat,
        minimumSize: CGSize,
        maximumSize: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        let visibleFrame = usableVisibleFrame(visibleFrame)
        let frame = frame.standardized
        guard visibleFrame.width > 0,
              visibleFrame.height > 0,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0,
              scaleFactor.isFinite,
              scaleFactor > 0 else {
            return clamped(frame: frame, to: visibleFrame)
        }

        let minimumWidth = finitePositive(minimumSize.width)
        let minimumHeight = finitePositive(minimumSize.height)
        let maximumWidth = min(
            finitePositive(maximumSize.width),
            visibleFrame.width
        )
        let maximumHeight = min(
            finitePositive(maximumSize.height),
            visibleFrame.height
        )
        guard maximumWidth > 0, maximumHeight > 0 else {
            return clamped(frame: frame, to: visibleFrame)
        }

        let minimumScale = max(
            minimumWidth / frame.width,
            minimumHeight / frame.height
        )
        let maximumScale = min(
            maximumWidth / frame.width,
            maximumHeight / frame.height
        )
        let appliedScale: CGFloat
        if minimumScale <= maximumScale {
            appliedScale = min(max(scaleFactor, minimumScale), maximumScale)
        } else {
            // A very small display can make the configured minimum impossible;
            // remaining visible takes precedence over the preferred minimum.
            appliedScale = maximumScale
        }

        let anchor = CGPoint(
            x: screenPoint.x.isFinite ? screenPoint.x : frame.midX,
            y: screenPoint.y.isFinite ? screenPoint.y : frame.midY
        )
        let unitX = min(max((anchor.x - frame.minX) / frame.width, 0), 1)
        let unitY = min(max((anchor.y - frame.minY) / frame.height, 0), 1)
        let size = CGSize(
            width: frame.width * appliedScale,
            height: frame.height * appliedScale
        )
        let proposed = CGRect(
            x: anchor.x - unitX * size.width,
            y: anchor.y - unitY * size.height,
            width: size.width,
            height: size.height
        )
        return clamped(frame: proposed, to: visibleFrame)
    }

    private static func usableVisibleFrame(_ frame: CGRect) -> CGRect {
        guard !frame.isNull,
              !frame.isInfinite,
              frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite else {
            return .zero
        }
        return frame.standardized
    }

    private static func usableSourceSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: max(1, finitePositive(size.width)),
            height: max(1, finitePositive(size.height))
        )
    }

    private static func finitePositive(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return 0 }
        return value
    }
}

/// Maps AppKit's already user-preference-adjusted scroll deltas into bounded,
/// multiplicative zoom. Momentum is intentionally ignored so a trackpad does
/// not keep resizing the image after the user lifts their fingers.
struct PinnedScreenshotScrollZoom {
    static func scaleFactor(
        deltaX: CGFloat,
        deltaY: CGFloat,
        hasPreciseDeltas: Bool,
        hasMomentum: Bool
    ) -> CGFloat? {
        guard !hasMomentum,
              deltaX.isFinite,
              deltaY.isFinite,
              abs(deltaY) > abs(deltaX),
              deltaY != 0 else {
            return nil
        }

        let exponent = hasPreciseDeltas
            ? Double(deltaY) * 0.01
            : Double(deltaY) * log(1.10)
        let boundedExponent = min(max(exponent, log(0.5)), log(2))
        return CGFloat(exp(boundedExponent))
    }
}

/// A self-contained display image. It never relies on the managed screenshot
/// draft, which can be removed as soon as the editor closes.
struct PinnedScreenshotSnapshot {
    static let defaultMaximumPixelCount = 3_000_000

    let image: CGImage
    let sourcePixelSize: CGSize
    let byteCost: Int

    init(
        image sourceImage: CGImage,
        maximumPixelCount: Int = defaultMaximumPixelCount
    ) throws {
        guard sourceImage.width > 0,
              sourceImage.height > 0,
              maximumPixelCount > 0 else {
            throw PinnedScreenshotFeatureError.invalidImage
        }

        sourcePixelSize = CGSize(
            width: sourceImage.width,
            height: sourceImage.height
        )

        let sourcePixelCount = Double(sourceImage.width) * Double(sourceImage.height)
        if sourcePixelCount <= Double(maximumPixelCount) {
            image = sourceImage
        } else {
            let scale = sqrt(Double(maximumPixelCount) / sourcePixelCount)
            var targetWidth = max(1, Int((Double(sourceImage.width) * scale).rounded(.down)))
            var targetHeight = max(1, Int((Double(sourceImage.height) * scale).rounded(.down)))

            while targetWidth * targetHeight > maximumPixelCount {
                if targetWidth >= targetHeight {
                    targetWidth -= 1
                } else {
                    targetHeight -= 1
                }
            }

            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw PinnedScreenshotFeatureError.snapshotCreationFailed
            }
            context.interpolationQuality = .high
            context.setBlendMode(.copy)
            context.draw(
                sourceImage,
                in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
            )
            guard let downsampled = context.makeImage() else {
                throw PinnedScreenshotFeatureError.snapshotCreationFailed
            }
            image = downsampled
        }

        let (cost, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard !overflow, cost > 0 else {
            throw PinnedScreenshotFeatureError.invalidImage
        }
        byteCost = cost
    }
}

@MainActor
enum PinnedScreenshotEscapeShortcut {
    enum Decision: Equatable {
        case ignore
        case consume
        case close
    }

    private static let disallowedModifiers: NSEvent.ModifierFlags = [
        .command,
        .control,
        .option,
        .shift,
        .function,
        .help,
    ]

    static func decision(
        for event: NSEvent,
        isKeyWindow: Bool,
        hasAttachedSheet: Bool = false
    ) -> Decision {
        guard isKeyWindow,
              !hasAttachedSheet,
              event.type == .keyDown,
              event.keyCode == 53,
              event.modifierFlags.intersection(disallowedModifiers).isEmpty else {
            return .ignore
        }
        return event.isARepeat ? .consume : .close
    }
}

@MainActor
final class PinnedScreenshotPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var onScrollZoom: (@MainActor (NSEvent) -> Void)?
    var onBareEscapeClose: (@MainActor () -> Void)?

    private(set) var isClosedForVisibilityRecovery = false
    private(set) var temporaryVisibilitySuppressionDepth = 0

    var isTemporarilyVisibilitySuppressed: Bool {
        temporaryVisibilitySuppressionDepth > 0
    }

    var allowsVisibilityRecovery: Bool {
        !isClosedForVisibilityRecovery
    }

    init(
        contentRect: CGRect,
        sourcePixelSize: CGSize,
        maximumContentSize: CGSize
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        title = "固定截图 — 一爪"
        isReleasedWhenClosed = false
        isFloatingPanel = true
        // Clicking a nonactivating pin should make only that panel the
        // keyboard target so Escape can close it without activating OnePaw.
        becomesKeyOnlyIfNeeded = false
        level = .floating
        hidesOnDeactivate = false
        canHide = false
        sharingType = .none
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        acceptsMouseMovedEvents = true
        allowsToolTipsWhenApplicationIsInactive = true
        animationBehavior = .utilityWindow
        tabbingMode = .disallowed

        let sourceSize = CGSize(
            width: max(1, sourcePixelSize.width),
            height: max(1, sourcePixelSize.height)
        )
        contentAspectRatio = sourceSize
        contentMinSize = PinnedScreenshotLayout.minimumContentSize(
            for: sourceSize
        )
        contentMaxSize = maximumContentSize
        setAccessibilityLabel("固定的截图")
    }

    override func close() {
        // Closing a pin is the user's permanent decision for this process.
        // Delayed wake/Space recovery and an outstanding capture scope must
        // never order this window onscreen again.
        isClosedForVisibilityRecovery = true
        super.close()
    }

    func beginTemporaryVisibilitySuppression() {
        guard allowsVisibilityRecovery else { return }
        temporaryVisibilitySuppressionDepth += 1
        orderOut(nil)
    }

    func endTemporaryVisibilitySuppression() {
        guard temporaryVisibilitySuppressionDepth > 0 else { return }
        temporaryVisibilitySuppressionDepth -= 1
        guard temporaryVisibilitySuppressionDepth == 0 else { return }
        recoverVisibilityAfterSystemTransition()
    }

    func recoverVisibilityAfterSystemTransition() {
        guard allowsVisibilityRecovery,
              !isTemporarilyVisibilitySuppressed else {
            return
        }
        level = .floating
        orderFrontRegardless()
    }

    override func sendEvent(_ event: NSEvent) {
        switch PinnedScreenshotEscapeShortcut.decision(
            for: event,
            isKeyWindow: isKeyWindow,
            hasAttachedSheet: attachedSheet != nil
        ) {
        case .ignore:
            break
        case .consume:
            // Do not let a held Escape key cascade into another pinned panel.
            return
        case .close:
            guard let onBareEscapeClose else {
                super.sendEvent(event)
                return
            }
            onBareEscapeClose()
            return
        }

        if event.type == .scrollWheel, let onScrollZoom {
            onScrollZoom(event)
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
private final class PinnedScreenshotCloseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

@MainActor
private final class PinnedScreenshotImageView: NSImageView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
}

@MainActor
private final class PinnedScreenshotContentView: NSView {
    private let closeButton = PinnedScreenshotCloseButton()
    private let onClose: @MainActor () -> Void
    private var trackingAreaReference: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { true }

    init(image: CGImage, onClose: @escaping @MainActor () -> Void) {
        self.onClose = onClose
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor

        let imageView = PinnedScreenshotImageView()
        imageView.image = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        imageView.isEditable = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        // The window owns sizing. Without low fitting priorities AppKit may
        // expand this borderless panel to the downsampled image's pixel size
        // when it is first ordered onscreen.
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setAccessibilityRole(.image)
        imageView.setAccessibilityLabel("截图贴图预览")
        imageView.setAccessibilityHelp("拖动可移动贴图，滚动鼠标滚轮可放大或缩小，按 Esc 可关闭")
        imageView.toolTip = "拖动移动，滚轮缩放，Esc 关闭"
        addSubview(imageView)

        closeButton.title = ""
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "关闭贴图"
        )
        closeButton.contentTintColor = .white
        closeButton.wantsLayer = true
        closeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.58).cgColor
        closeButton.layer?.cornerRadius = 12
        closeButton.toolTip = "关闭贴图（Esc）"
        closeButton.setAccessibilityLabel("关闭贴图")
        closeButton.setAccessibilityHelp("关闭这张临时贴图，也可以按 Esc")
        closeButton.target = self
        closeButton.action = #selector(closePinnedScreenshot(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = true
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
    }

    @objc
    private func closePinnedScreenshot(_ sender: NSButton) {
        onClose()
    }
}

@MainActor
final class PinnedScreenshotWindowController: NSWindowController, NSWindowDelegate {
    typealias CloseHandler = @MainActor (UUID) -> Void

    let id: UUID
    let snapshot: PinnedScreenshotSnapshot
    private var onClose: CloseHandler?

    init(
        id: UUID,
        snapshot: PinnedScreenshotSnapshot,
        initialFrame: CGRect,
        maximumContentSize: CGSize,
        onClose: @escaping CloseHandler
    ) {
        self.id = id
        self.snapshot = snapshot
        self.onClose = onClose

        let panel = PinnedScreenshotPanel(
            contentRect: initialFrame,
            sourcePixelSize: snapshot.sourcePixelSize,
            maximumContentSize: maximumContentSize
        )
        super.init(window: panel)
        panel.delegate = self
        panel.onScrollZoom = { [weak self, weak panel] event in
            guard let self, let panel else { return }
            self.handleScrollZoom(event, in: panel)
        }
        panel.onBareEscapeClose = { [weak self] in
            self?.close()
        }
        panel.contentView = PinnedScreenshotContentView(
            image: snapshot.image,
            onClose: { [weak self] in
                self?.close()
            }
        )
        panel.setFrame(initialFrame, display: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(selectForKeyboard: Bool = false) {
        guard let panel = window as? PinnedScreenshotPanel else { return }
        // Ordering alone must not steal keyboard focus from another app.
        panel.recoverVisibilityAfterSystemTransition()
        if selectForKeyboard {
            panel.makeKey()
        }
    }

    func recoverVisibilityAfterSystemTransition() {
        (window as? PinnedScreenshotPanel)?
            .recoverVisibilityAfterSystemTransition()
    }

    func recoverVisibilityIfUnexpectedlyHidden() {
        guard let panel = window as? PinnedScreenshotPanel,
              !panel.isVisible else {
            return
        }
        panel.recoverVisibilityAfterSystemTransition()
    }

    override func close() {
        window?.close()
    }

    func clamp(to visibleFrame: CGRect) {
        guard let window else { return }
        let adjusted = PinnedScreenshotLayout.clamped(
            frame: window.frame,
            to: visibleFrame
        )
        window.setFrame(adjusted, display: true)
    }

    func applyScrollZoom(
        scaleFactor: CGFloat,
        around screenPoint: CGPoint,
        visibleFrame: CGRect
    ) {
        guard let window else { return }
        let maximumSize = PinnedScreenshotLayout.maximumContentSize(
            for: visibleFrame
        )
        window.contentMaxSize = maximumSize
        let adjusted = PinnedScreenshotLayout.zoomedFrame(
            frame: window.frame,
            around: screenPoint,
            scaleFactor: scaleFactor,
            minimumSize: window.contentMinSize,
            maximumSize: maximumSize,
            visibleFrame: visibleFrame
        )
        guard adjusted != window.frame else { return }
        window.setFrame(adjusted, display: true, animate: false)
    }

    private func handleScrollZoom(_ event: NSEvent, in panel: PinnedScreenshotPanel) {
        guard let scaleFactor = PinnedScreenshotScrollZoom.scaleFactor(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            hasMomentum: !event.momentumPhase.isEmpty
        ) else {
            return
        }

        let screenPoint = panel.convertPoint(toScreen: event.locationInWindow)
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(screenPoint, $0.frame, false)
        }) ?? panel.screen ?? NSScreen.screens.first else {
            return
        }
        applyScrollZoom(
            scaleFactor: scaleFactor,
            around: screenPoint,
            visibleFrame: screen.visibleFrame
        )
    }

    func windowWillClose(_ notification: Notification) {
        if let panel = window as? PinnedScreenshotPanel {
            panel.onScrollZoom = nil
            panel.onBareEscapeClose = nil
        }
        window?.delegate = nil
        let handler = onClose
        onClose = nil
        handler?(id)
    }
}

@MainActor
final class PinnedScreenshotManager: NSObject {
    nonisolated static let defaultMemoryBudgetBytes = 128 * 1_024 * 1_024

    private static let delayedRecoveryNanoseconds: UInt64 = 300_000_000
    private static let visibilityWatchdogNanoseconds: UInt64 = 5_000_000_000

    private let memoryBudgetBytes: Int
    private let maximumSnapshotPixelCount: Int
    private let workspaceNotificationCenter: NotificationCenter
    private var controllers: [UUID: PinnedScreenshotWindowController] = [:]
    private var delayedRecoveryTask: Task<Void, Never>?
    private var visibilityWatchdogTask: Task<Void, Never>?

    private(set) var count = 0
    private(set) var totalByteCost = 0

    init(
        memoryBudgetBytes: Int = defaultMemoryBudgetBytes,
        maximumSnapshotPixelCount: Int = PinnedScreenshotSnapshot.defaultMaximumPixelCount
    ) {
        self.memoryBudgetBytes = max(1, memoryBudgetBytes)
        self.maximumSnapshotPixelCount = max(1, maximumSnapshotPixelCount)
        workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        for name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ] {
            workspaceNotificationCenter.addObserver(
                self,
                selector: #selector(workspaceVisibilityMayHaveChanged(_:)),
                name: name,
                object: nil
            )
        }
        startVisibilityWatchdog()
    }

    deinit {
        delayedRecoveryTask?.cancel()
        visibilityWatchdogTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        workspaceNotificationCenter.removeObserver(self)
    }

    @discardableResult
    func pin(
        image: CGImage,
        anchor: CGPoint = NSEvent.mouseLocation,
        targetScreen: NSScreen? = nil,
        selectForKeyboard: Bool = false
    ) throws -> UUID {
        guard let screen = targetScreen ?? screen(containing: anchor) ?? NSScreen.main
            ?? NSScreen.screens.first else {
            throw PinnedScreenshotFeatureError.noAvailableScreen
        }

        let snapshot = try PinnedScreenshotSnapshot(
            image: image,
            maximumPixelCount: maximumSnapshotPixelCount
        )
        let availableBytes = max(0, memoryBudgetBytes - totalByteCost)
        guard snapshot.byteCost <= availableBytes else {
            throw PinnedScreenshotFeatureError.memoryBudgetExceeded(
                requiredBytes: snapshot.byteCost,
                availableBytes: availableBytes
            )
        }

        let id = UUID()
        let initialFrame = PinnedScreenshotLayout.initialFrame(
            sourcePixelSize: snapshot.sourcePixelSize,
            backingScaleFactor: screen.backingScaleFactor,
            visibleFrame: screen.visibleFrame,
            anchor: anchor
        )
        let maximumContentSize = PinnedScreenshotLayout.maximumContentSize(
            for: screen.visibleFrame
        )
        let controller = PinnedScreenshotWindowController(
            id: id,
            snapshot: snapshot,
            initialFrame: initialFrame,
            maximumContentSize: maximumContentSize,
            onClose: { [weak self] id in
                self?.removeController(id: id)
            }
        )

        // Strong ownership is established before ordering the panel onscreen.
        controllers[id] = controller
        count = controllers.count
        totalByteCost += snapshot.byteCost
        controller.show(selectForKeyboard: selectForKeyboard)
        return id
    }

    func close(id: UUID) {
        controllers[id]?.close()
    }

    func closeAll() {
        for controller in Array(controllers.values) {
            controller.close()
        }
    }

    func contains(id: UUID) -> Bool {
        controllers[id] != nil
    }

    func frame(for id: UUID) -> CGRect? {
        controllers[id]?.window?.frame
    }

    @objc nonisolated
    private func screenParametersDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.recoverAfterSystemTransition()
        }
    }

    @objc nonisolated
    private func workspaceVisibilityMayHaveChanged(_ notification: Notification) {
        // NSWorkspace notifications are not contractually tied to the main
        // queue. Marshal every AppKit window mutation onto MainActor.
        Task { @MainActor [weak self] in
            self?.recoverAfterSystemTransition()
        }
    }

    private func removeController(id: UUID) {
        guard let controller = controllers.removeValue(forKey: id) else { return }
        count = controllers.count
        totalByteCost = max(0, totalByteCost - controller.snapshot.byteCost)
    }

    private func clampAllToAvailableScreens() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        for controller in controllers.values {
            guard let frame = controller.window?.frame,
                  let screen = bestScreen(for: frame, among: screens) else {
                continue
            }
            controller.clamp(to: screen.visibleFrame)
        }
    }

    private func recoverAfterSystemTransition() {
        recoverAllVisiblePins()

        // Wake and display notifications can arrive before WindowServer has
        // finished rebuilding Spaces and screen geometry. Coalesce a short
        // second pass so the final topology also receives the recovery.
        delayedRecoveryTask?.cancel()
        delayedRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: Self.delayedRecoveryNanoseconds
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.recoverAllVisiblePins()
        }
    }

    private func recoverAllVisiblePins() {
        guard !NSScreen.screens.isEmpty else { return }
        clampAllToAvailableScreens()
        for controller in controllers.values {
            controller.recoverVisibilityAfterSystemTransition()
        }
    }

    private func startVisibilityWatchdog() {
        visibilityWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        nanoseconds: Self.visibilityWatchdogNanoseconds
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.recoverUnexpectedlyHiddenPins()
            }
        }
    }

    private func recoverUnexpectedlyHiddenPins() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        for controller in controllers.values {
            guard let panel = controller.window as? PinnedScreenshotPanel,
                  panel.allowsVisibilityRecovery,
                  !panel.isTemporarilyVisibilitySuppressed,
                  !panel.isVisible,
                  let screen = bestScreen(for: panel.frame, among: screens) else {
                continue
            }
            controller.clamp(to: screen.visibleFrame)
            controller.recoverVisibilityIfUnexpectedlyHidden()
        }
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            NSMouseInRect(point, screen.frame, false)
        }
    }

    private func bestScreen(for frame: CGRect, among screens: [NSScreen]) -> NSScreen? {
        let intersecting = screens
            .map { screen in
                let intersection = frame.intersection(screen.visibleFrame)
                let area = intersection.isNull
                    ? 0
                    : max(0, intersection.width) * max(0, intersection.height)
                return (screen: screen, area: area)
            }
            .max { lhs, rhs in lhs.area < rhs.area }

        if let intersecting, intersecting.area > 0 {
            return intersecting.screen
        }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        return screens.min { lhs, rhs in
            distanceSquared(from: center, to: lhs.visibleFrame)
                < distanceSquared(from: center, to: rhs.visibleFrame)
        }
    }

    private func distanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let x = min(max(point.x, rect.minX), rect.maxX)
        let y = min(max(point.y, rect.minY), rect.maxY)
        let dx = point.x - x
        let dy = point.y - y
        return dx * dx + dy * dy
    }
}
