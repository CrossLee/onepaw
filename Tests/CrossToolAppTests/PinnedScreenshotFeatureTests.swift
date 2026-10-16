import AppKit
import CoreGraphics
@testable import CrossToolApp
import Testing

@MainActor
private final class PinnedScreenshotKeyEventProbe: NSView {
    override var acceptsFirstResponder: Bool { true }

    private(set) var receivedKeyCodes: [UInt16] = []

    override func keyDown(with event: NSEvent) {
        receivedKeyCodes.append(event.keyCode)
    }
}

@MainActor
@Suite("Pinned screenshot feature", .serialized)
struct PinnedScreenshotFeatureTests {
    @Test("Initial frames preserve image geometry near the anchor on a negative-X display")
    func initialFramesPreserveGeometryAtOneAndTwoTimesScale() {
        let visibleFrame = CGRect(x: -1_920, y: 23, width: 1_920, height: 1_057)
        let anchor = CGPoint(x: -960, y: 850)
        let sourceSizes = [
            CGSize(width: 800, height: 400),
            CGSize(width: 400, height: 800),
            CGSize(width: 240, height: 6_000),
        ]

        for backingScaleFactor in [CGFloat(1), CGFloat(2)] {
            for sourceSize in sourceSizes {
                let frame = PinnedScreenshotLayout.initialFrame(
                    sourcePixelSize: sourceSize,
                    backingScaleFactor: backingScaleFactor,
                    visibleFrame: visibleFrame,
                    anchor: anchor
                )

                #expect(isContained(frame, in: visibleFrame))
                #expect(frame.maxX <= 0)
                #expect(frame.width <= PinnedScreenshotLayout.maximumInitialWidth + 0.001)
                #expect(frame.height <= PinnedScreenshotLayout.maximumInitialHeight + 0.001)
                #expect(
                    frame.width
                        <= visibleFrame.width
                            * PinnedScreenshotLayout.maximumVisibleFrameFraction + 0.001
                )
                #expect(
                    frame.height
                        <= visibleFrame.height
                            * PinnedScreenshotLayout.maximumVisibleFrameFraction + 0.001
                )
                #expect(
                    abs(frame.width / frame.height - sourceSize.width / sourceSize.height)
                        < 0.000_1
                )
                #expect(
                    distance(from: anchor, to: frame)
                        <= PinnedScreenshotLayout.anchorGap * sqrt(2) + 0.001
                )
            }
        }
    }

    @Test("Clamp recovers oversized and disconnected-display frames")
    func clampRecoversOffscreenFrames() {
        let negativeVisibleFrame = CGRect(x: -1_920, y: 23, width: 1_920, height: 1_057)
        let oversized = CGRect(x: -3_800, y: 1_400, width: 4_000, height: 2_000)
        let fitted = PinnedScreenshotLayout.clamped(
            frame: oversized,
            to: negativeVisibleFrame
        )

        #expect(isContained(fitted, in: negativeVisibleFrame))
        #expect(abs(fitted.width / fitted.height - 2) < 0.000_1)

        let disconnectedDisplayFrame = CGRect(x: -1_700, y: 620, width: 480, height: 240)
        let remainingMainDisplay = CGRect(x: 0, y: 25, width: 1_440, height: 875)
        let recovered = PinnedScreenshotLayout.clamped(
            frame: disconnectedDisplayFrame,
            to: remainingMainDisplay
        )

        #expect(isContained(recovered, in: remainingMainDisplay))
        #expect(recovered.size == disconnectedDisplayFrame.size)
        #expect(recovered.minX == remainingMainDisplay.minX)
    }

    @Test("Scroll zoom maps wheel and trackpad deltas without double-inverting AppKit direction")
    func scrollZoomScaleFactorsHonorPrecisionAndConfiguredDirection() throws {
        let coarseZoomIn = try #require(PinnedScreenshotScrollZoom.scaleFactor(
            deltaX: 0,
            deltaY: 1,
            hasPreciseDeltas: false,
            hasMomentum: false
        ))
        let coarseZoomOut = try #require(PinnedScreenshotScrollZoom.scaleFactor(
            deltaX: 0,
            deltaY: -1,
            hasPreciseDeltas: false,
            hasMomentum: false
        ))
        let preciseQuarterPoint = try #require(PinnedScreenshotScrollZoom.scaleFactor(
            deltaX: 0,
            deltaY: 0.25,
            hasPreciseDeltas: true,
            hasMomentum: false
        ))

        #expect(isApproximatelyEqual(coarseZoomIn, 1.10))
        #expect(isApproximatelyEqual(coarseZoomOut, 1 / 1.10))
        #expect(coarseZoomIn > 1)
        #expect(coarseZoomOut < 1)
        #expect(preciseQuarterPoint > 1)
        #expect(preciseQuarterPoint < coarseZoomIn)

        // `scrollingDeltaY` is already inverted by AppKit when the user's
        // natural-scrolling preference requires it. Its delivered sign must be
        // consumed exactly once: positive grows and negative shrinks.
        #expect(isApproximatelyEqual(coarseZoomIn * coarseZoomOut, 1))

        var accumulatedPreciseScale: CGFloat = 1
        for _ in 0..<40 {
            accumulatedPreciseScale *= preciseQuarterPoint
        }
        let oneTenPointGesture = try #require(PinnedScreenshotScrollZoom.scaleFactor(
            deltaX: 0,
            deltaY: 10,
            hasPreciseDeltas: true,
            hasMomentum: false
        ))
        #expect(isApproximatelyEqual(
            accumulatedPreciseScale,
            oneTenPointGesture,
            tolerance: 0.000_001
        ))

        let boundedLargeZoomIn = try #require(PinnedScreenshotScrollZoom.scaleFactor(
            deltaX: 0,
            deltaY: 10_000,
            hasPreciseDeltas: true,
            hasMomentum: false
        ))
        let boundedLargeZoomOut = try #require(PinnedScreenshotScrollZoom.scaleFactor(
            deltaX: 0,
            deltaY: -10_000,
            hasPreciseDeltas: true,
            hasMomentum: false
        ))
        #expect(boundedLargeZoomIn == 2)
        #expect(boundedLargeZoomOut == 0.5)
    }

    @Test("Scroll zoom ignores horizontal, momentum, zero, and invalid deltas")
    func scrollZoomRejectsNonVerticalOrInvalidInput() {
        #expect(PinnedScreenshotScrollZoom.scaleFactor(
            deltaX: 2,
            deltaY: 1,
            hasPreciseDeltas: true,
            hasMomentum: false
        ) == nil)
        #expect(PinnedScreenshotScrollZoom.scaleFactor(
            deltaX: 1,
            deltaY: 1,
            hasPreciseDeltas: true,
            hasMomentum: false
        ) == nil)
        #expect(PinnedScreenshotScrollZoom.scaleFactor(
            deltaX: 0,
            deltaY: 1,
            hasPreciseDeltas: true,
            hasMomentum: true
        ) == nil)
        #expect(PinnedScreenshotScrollZoom.scaleFactor(
            deltaX: 0,
            deltaY: 0,
            hasPreciseDeltas: false,
            hasMomentum: false
        ) == nil)
        #expect(PinnedScreenshotScrollZoom.scaleFactor(
            deltaX: .nan,
            deltaY: 1,
            hasPreciseDeltas: false,
            hasMomentum: false
        ) == nil)
        #expect(PinnedScreenshotScrollZoom.scaleFactor(
            deltaX: 0,
            deltaY: .infinity,
            hasPreciseDeltas: false,
            hasMomentum: false
        ) == nil)
        #expect(PinnedScreenshotScrollZoom.scaleFactor(
            deltaX: 0.2,
            deltaY: 1,
            hasPreciseDeltas: true,
            hasMomentum: false
        ) != nil)
    }

    @Test("Zoom keeps the same image point under the cursor until a screen edge binds")
    func zoomedFramePreservesCursorAnchor() {
        let frame = CGRect(x: 300, y: 260, width: 400, height: 200)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
        let minimumSize = CGSize(width: 120, height: 60)
        let maximumSize = CGSize(width: 900, height: 700)
        let normalizedAnchors = [
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.25, y: 0.75),
        ]

        for normalizedAnchor in normalizedAnchors {
            let cursor = point(in: frame, at: normalizedAnchor)
            for factor in [CGFloat(1.25), CGFloat(0.8)] {
                let zoomed = PinnedScreenshotLayout.zoomedFrame(
                    frame: frame,
                    around: cursor,
                    scaleFactor: factor,
                    minimumSize: minimumSize,
                    maximumSize: maximumSize,
                    visibleFrame: visibleFrame
                )

                #expect(isApproximatelyEqual(zoomed.width, frame.width * factor))
                #expect(isApproximatelyEqual(zoomed.height, frame.height * factor))
                #expect(isApproximatelyEqual(zoomed.width / zoomed.height, 2))
                #expect(pointsAreApproximatelyEqual(
                    normalizedPosition(of: cursor, in: zoomed),
                    normalizedAnchor
                ))
            }
        }
    }

    @Test("Zoom preserves wide, portrait, and very tall screenshot aspect ratios")
    func zoomedFramePreservesDifferentSourceAspectRatios() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 2_000, height: 1_200)
        let cases: [(frame: CGRect, minimumSize: CGSize)] = [
            (
                CGRect(x: 300, y: 300, width: 400, height: 200),
                CGSize(width: 120, height: 60)
            ),
            (
                CGRect(x: 600, y: 250, width: 180, height: 360),
                CGSize(width: 60, height: 120)
            ),
            (
                CGRect(x: 900, y: 180, width: 80, height: 400),
                CGSize(width: 24, height: 120)
            ),
        ]

        for testCase in cases {
            let cursor = point(
                in: testCase.frame,
                at: CGPoint(x: 0.4, y: 0.6)
            )
            let zoomed = PinnedScreenshotLayout.zoomedFrame(
                frame: testCase.frame,
                around: cursor,
                scaleFactor: 1.5,
                minimumSize: testCase.minimumSize,
                maximumSize: CGSize(width: 1_600, height: 1_000),
                visibleFrame: visibleFrame
            )

            #expect(isApproximatelyEqual(
                zoomed.width / zoomed.height,
                testCase.frame.width / testCase.frame.height
            ))
            #expect(pointsAreApproximatelyEqual(
                normalizedPosition(of: cursor, in: zoomed),
                CGPoint(x: 0.4, y: 0.6)
            ))
        }
    }

    @Test("Smooth precise deltas resize monotonically without losing the cursor anchor")
    func smoothPreciseZoomSequenceIsStable() throws {
        let visibleFrame = CGRect(x: 0, y: 0, width: 2_000, height: 1_200)
        let minimumSize = CGSize(width: 120, height: 60)
        let maximumSize = CGSize(width: 1_200, height: 800)
        let initialFrame = CGRect(x: 400, y: 350, width: 300, height: 150)
        let cursor = point(in: initialFrame, at: CGPoint(x: 0.3, y: 0.7))
        let eventScale = try #require(PinnedScreenshotScrollZoom.scaleFactor(
            deltaX: 0,
            deltaY: 0.25,
            hasPreciseDeltas: true,
            hasMomentum: false
        ))
        var sequentialFrame = initialFrame

        for _ in 0..<40 {
            let previousFrame = sequentialFrame
            sequentialFrame = PinnedScreenshotLayout.zoomedFrame(
                frame: sequentialFrame,
                around: cursor,
                scaleFactor: eventScale,
                minimumSize: minimumSize,
                maximumSize: maximumSize,
                visibleFrame: visibleFrame
            )
            #expect(sequentialFrame.width > previousFrame.width)
            #expect(pointsAreApproximatelyEqual(
                normalizedPosition(of: cursor, in: sequentialFrame),
                CGPoint(x: 0.3, y: 0.7)
            ))
        }

        let combinedScale = try #require(PinnedScreenshotScrollZoom.scaleFactor(
            deltaX: 0,
            deltaY: 10,
            hasPreciseDeltas: true,
            hasMomentum: false
        ))
        let oneStepFrame = PinnedScreenshotLayout.zoomedFrame(
            frame: initialFrame,
            around: cursor,
            scaleFactor: combinedScale,
            minimumSize: minimumSize,
            maximumSize: maximumSize,
            visibleFrame: visibleFrame
        )

        #expect(rectsAreApproximatelyEqual(
            sequentialFrame,
            oneStepFrame,
            tolerance: 0.000_1
        ))
    }

    @Test("Zoom clamps exactly and idempotently to content minimum and maximum")
    func zoomedFrameHonorsMinimumAndMaximumSizes() {
        let frame = CGRect(x: 500, y: 400, width: 400, height: 200)
        let cursor = point(in: frame, at: CGPoint(x: 0.2, y: 0.8))
        let visibleFrame = CGRect(x: 0, y: 0, width: 2_000, height: 1_200)
        let minimumSize = CGSize(width: 120, height: 60)
        let maximumSize = CGSize(width: 900, height: 700)

        let minimumFrame = PinnedScreenshotLayout.zoomedFrame(
            frame: frame,
            around: cursor,
            scaleFactor: 0.001,
            minimumSize: minimumSize,
            maximumSize: maximumSize,
            visibleFrame: visibleFrame
        )
        let minimumAgain = PinnedScreenshotLayout.zoomedFrame(
            frame: minimumFrame,
            around: cursor,
            scaleFactor: 0.5,
            minimumSize: minimumSize,
            maximumSize: maximumSize,
            visibleFrame: visibleFrame
        )
        #expect(minimumFrame.size == CGSize(width: 120, height: 60))
        #expect(minimumAgain == minimumFrame)

        let maximumFrame = PinnedScreenshotLayout.zoomedFrame(
            frame: frame,
            around: cursor,
            scaleFactor: 1_000,
            minimumSize: minimumSize,
            maximumSize: maximumSize,
            visibleFrame: visibleFrame
        )
        let maximumAgain = PinnedScreenshotLayout.zoomedFrame(
            frame: maximumFrame,
            around: cursor,
            scaleFactor: 2,
            minimumSize: minimumSize,
            maximumSize: maximumSize,
            visibleFrame: visibleFrame
        )
        #expect(maximumFrame.size == CGSize(width: 900, height: 450))
        #expect(maximumAgain == maximumFrame)
        #expect(isApproximatelyEqual(maximumFrame.width / maximumFrame.height, 2))
    }

    @Test("Zoom remains visible and proportional at every corner of a negative-X display")
    func zoomedFrameHandlesNegativeDisplayCoordinatesAndEdges() {
        let visibleFrame = CGRect(x: -1_920, y: 23, width: 1_920, height: 1_057)
        let framesAndAnchors = [
            (CGRect(x: -1_915, y: 28, width: 400, height: 200), CGPoint(x: -1_905, y: 38)),
            (CGRect(x: -405, y: 28, width: 400, height: 200), CGPoint(x: -15, y: 38)),
            (CGRect(x: -1_915, y: 875, width: 400, height: 200), CGPoint(x: -1_905, y: 1_065)),
            (CGRect(x: -405, y: 875, width: 400, height: 200), CGPoint(x: -15, y: 1_065)),
        ]

        for (frame, cursor) in framesAndAnchors {
            let zoomed = PinnedScreenshotLayout.zoomedFrame(
                frame: frame,
                around: cursor,
                scaleFactor: 1.8,
                minimumSize: CGSize(width: 120, height: 60),
                maximumSize: CGSize(width: 1_800, height: 1_000),
                visibleFrame: visibleFrame
            )

            #expect(isContained(zoomed, in: visibleFrame))
            #expect(zoomed.maxX <= 0)
            #expect(isApproximatelyEqual(zoomed.width / zoomed.height, 2))
            #expect(
                isApproximatelyEqual(zoomed.minX, visibleFrame.minX)
                    || isApproximatelyEqual(zoomed.maxX, visibleFrame.maxX)
                    || isApproximatelyEqual(zoomed.minY, visibleFrame.minY)
                    || isApproximatelyEqual(zoomed.maxY, visibleFrame.maxY)
            )
        }
    }

    @Test("Controller scroll zoom preserves panel constraints and source aspect ratio")
    func controllerAppliesScrollZoomWithoutBreakingManualResizePolicy() throws {
        let snapshot = try PinnedScreenshotSnapshot(
            image: makeImage(width: 800, height: 400)
        )
        let initialFrame = CGRect(x: 300, y: 260, width: 320, height: 160)
        let maximumContentSize = CGSize(width: 900, height: 700)
        let controller = PinnedScreenshotWindowController(
            id: UUID(),
            snapshot: snapshot,
            initialFrame: initialFrame,
            maximumContentSize: maximumContentSize,
            onClose: { _ in }
        )
        let window = try #require(controller.window)
        defer {
            window.delegate = nil
            window.close()
        }
        let originalAspectRatio = window.contentAspectRatio
        let originalMinimumSize = window.contentMinSize
        let cursor = point(in: initialFrame, at: CGPoint(x: 0.25, y: 0.75))
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)

        controller.applyScrollZoom(
            scaleFactor: 1.25,
            around: cursor,
            visibleFrame: visibleFrame
        )

        let zoomedFrame = window.frame
        #expect(isApproximatelyEqual(zoomedFrame.width, 400))
        #expect(isApproximatelyEqual(zoomedFrame.height, 200))
        #expect(pointsAreApproximatelyEqual(
            normalizedPosition(of: cursor, in: zoomedFrame),
            CGPoint(x: 0.25, y: 0.75)
        ))
        #expect(window.contentAspectRatio == originalAspectRatio)
        #expect(window.contentMinSize == originalMinimumSize)
        #expect(
            window.contentMaxSize
                == PinnedScreenshotLayout.maximumContentSize(for: visibleFrame)
        )
        #expect(isApproximatelyEqual(
            zoomedFrame.width / zoomedFrame.height,
            snapshot.sourcePixelSize.width / snapshot.sourcePixelSize.height
        ))
    }

    @Test("Only the first bare Escape closes a key pinned panel")
    func escapeShortcutDecisionRequiresFirstBareKeyDown() throws {
        let bareEscape = try makeKeyEvent()
        let repeatedEscape = try makeKeyEvent(isARepeat: true)

        #expect(PinnedScreenshotEscapeShortcut.decision(
            for: bareEscape,
            isKeyWindow: true
        ) == .close)
        #expect(PinnedScreenshotEscapeShortcut.decision(
            for: repeatedEscape,
            isKeyWindow: true
        ) == .consume)
        #expect(PinnedScreenshotEscapeShortcut.decision(
            for: bareEscape,
            isKeyWindow: false
        ) == .ignore)

        for modifiers: NSEvent.ModifierFlags in [
            .command,
            .control,
            .option,
            .shift,
            .function,
            .help,
            [.command, .shift],
        ] {
            let modifiedEscape = try makeKeyEvent(modifierFlags: modifiers)
            #expect(PinnedScreenshotEscapeShortcut.decision(
                for: modifiedEscape,
                isKeyWindow: true
            ) == .ignore)
        }

        let capsLockEscape = try makeKeyEvent(modifierFlags: .capsLock)
        #expect(PinnedScreenshotEscapeShortcut.decision(
            for: capsLockEscape,
            isKeyWindow: true
        ) == .close)

        let escapeKeyUp = try makeKeyEvent(type: .keyUp)
        let bareA = try makeKeyEvent(characters: "a", keyCode: 0)
        for event in [escapeKeyUp, bareA] {
            #expect(PinnedScreenshotEscapeShortcut.decision(
                for: event,
                isKeyWindow: true
            ) == .ignore)
        }
    }

    @Test("Pinned panel passes unrelated keys and cleans handlers after Escape callback")
    func panelPassesUnrelatedKeysAndCleansEscapeHandler() throws {
        let snapshot = try PinnedScreenshotSnapshot(
            image: makeImage(width: 800, height: 400)
        )
        var closeCount = 0
        let controller = PinnedScreenshotWindowController(
            id: UUID(),
            snapshot: snapshot,
            initialFrame: CGRect(x: 260, y: 220, width: 320, height: 160),
            maximumContentSize: CGSize(width: 900, height: 700),
            onClose: { _ in closeCount += 1 }
        )
        let panel = try #require(controller.window as? PinnedScreenshotPanel)
        let probe = PinnedScreenshotKeyEventProbe(frame: .zero)
        panel.contentView?.addSubview(probe)
        defer {
            panel.onBareEscapeClose = nil
            panel.onScrollZoom = nil
            panel.delegate = nil
            panel.orderOut(nil)
            panel.close()
        }

        controller.show()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        #expect(panel.isVisible)
        #expect(!panel.becomesKeyOnlyIfNeeded)
        #expect(panel.onBareEscapeClose != nil)
        #expect(panel.onScrollZoom != nil)
        #expect(panel.makeFirstResponder(probe))

        panel.sendEvent(try makeKeyEvent(
            modifierFlags: .shift,
            windowNumber: panel.windowNumber
        ))
        panel.sendEvent(try makeKeyEvent(
            characters: "a",
            keyCode: 0,
            windowNumber: panel.windowNumber
        ))
        #expect(probe.receivedKeyCodes == [53, 0])
        #expect(closeCount == 0)

        // The pure decision test above covers key-window routing and repeat
        // consumption. Invoke the panel's selected-target callback here because
        // a SwiftPM XCTest host cannot become a real AppKit key application.
        panel.onBareEscapeClose?()

        #expect(closeCount == 1)
        #expect(!panel.isVisible)
        #expect(panel.onBareEscapeClose == nil)
        #expect(panel.onScrollZoom == nil)

        controller.close()
        #expect(closeCount == 1)
    }

    @Test("Inactive pinned panel dispatches each scroll-wheel event exactly once")
    func pinnedPanelDispatchesScrollWheelWithoutActivation() throws {
        let panel = PinnedScreenshotPanel(
            contentRect: CGRect(x: 260, y: 220, width: 320, height: 160),
            sourcePixelSize: CGSize(width: 800, height: 400),
            maximumContentSize: CGSize(width: 900, height: 700)
        )
        defer {
            panel.onScrollZoom = nil
            panel.orderOut(nil)
            panel.close()
        }

        var receivedEvents: [NSEvent] = []
        panel.onScrollZoom = { event in
            receivedEvents.append(event)
        }

        #expect(!panel.isKeyWindow)
        #expect(!panel.isMainWindow)

        // `sendEvent` receives window-routed events in production. Synthetic
        // CGEvents do not carry a stable NSWindow association, so dispatch them
        // directly while varying their nominal screen positions. This exercises
        // the panel-level scroll handler without activating the panel.
        let nominalLocations = [
            CGPoint(x: panel.frame.minX + 1, y: panel.frame.minY + 1),
            CGPoint(x: panel.frame.midX, y: panel.frame.midY),
            CGPoint(x: panel.frame.maxX - 1, y: panel.frame.maxY - 1),
        ]
        for (index, location) in nominalLocations.enumerated() {
            let cgEvent = try #require(CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 1,
                wheel1: 1,
                wheel2: 0,
                wheel3: 0
            ))
            cgEvent.location = location
            let event = try #require(NSEvent(cgEvent: cgEvent))
            #expect(event.type == .scrollWheel)

            panel.sendEvent(event)

            #expect(receivedEvents.count == index + 1)
            #expect(receivedEvents.last === event)
            #expect(!panel.isKeyWindow)
            #expect(!panel.isMainWindow)
        }
    }

    @Test("A large source is detached into a bounded snapshot with accountable memory")
    func snapshotDownsamplesAndReportsMemoryCost() throws {
        let source = try makeImage(width: 4_000, height: 3_000)

        let snapshot = try PinnedScreenshotSnapshot(image: source)
        let pixelCount = snapshot.image.width * snapshot.image.height

        #expect(snapshot.sourcePixelSize == CGSize(width: 4_000, height: 3_000))
        #expect(pixelCount <= PinnedScreenshotSnapshot.defaultMaximumPixelCount)
        #expect(pixelCount > 0)
        #expect(
            abs(
                Double(snapshot.image.width) / Double(snapshot.image.height)
                    - 4.0 / 3.0
            ) < 0.001
        )
        #expect(snapshot.byteCost > 0)
        #expect(snapshot.byteCost == snapshot.image.bytesPerRow * snapshot.image.height)
    }

    @Test("Pinned panel keeps its requested frame, aspect ratio, and utility-window policy")
    func pinnedPanelConfiguration() throws {
        let snapshot = try PinnedScreenshotSnapshot(
            image: makeImage(width: 800, height: 400)
        )
        let initialFrame = CGRect(x: 50, y: 60, width: 320, height: 160)
        let maximumContentSize = CGSize(width: 900, height: 700)
        var closeCount = 0
        let controller = PinnedScreenshotWindowController(
            id: UUID(),
            snapshot: snapshot,
            initialFrame: initialFrame,
            maximumContentSize: maximumContentSize,
            onClose: { _ in closeCount += 1 }
        )
        let window = try #require(controller.window)
        let panel = try #require(window as? PinnedScreenshotPanel)
        defer {
            window.delegate = nil
            window.close()
        }

        #expect(window is PinnedScreenshotPanel)
        #expect(window.styleMask == [.borderless, .nonactivatingPanel, .resizable])
        #expect(!window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.nonactivatingPanel))
        #expect(window.styleMask.contains(.resizable))
        #expect(window.level == .floating)
        #expect(window.sharingType == .none)
        #expect(!window.hidesOnDeactivate)
        #expect(window.isMovableByWindowBackground)
        #expect(window.canBecomeKey)
        #expect(!window.canBecomeMain)
        #expect(!panel.becomesKeyOnlyIfNeeded)
        #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(window.collectionBehavior.contains(.ignoresCycle))
        #expect(window.frame == initialFrame)
        #expect(window.contentAspectRatio == snapshot.sourcePixelSize)
        #expect(abs(window.frame.width / window.frame.height - 2) < 0.000_1)
        #expect(window.contentMaxSize == maximumContentSize)
        #expect(panel.allowsVisibilityRecovery)
        #expect(!panel.isTemporarilyVisibilitySuppressed)

        let contentView = try #require(window.contentView)
        let imageView = try #require(
            contentView.subviews.compactMap { $0 as? NSImageView }.first
        )
        let closeButton = try #require(
            contentView.subviews.compactMap { $0 as? NSButton }.first
        )
        #expect(contentView.acceptsFirstMouse(for: nil))
        #expect(contentView.mouseDownCanMoveWindow)
        #expect(imageView.acceptsFirstMouse(for: nil))
        #expect(imageView.mouseDownCanMoveWindow)
        #expect(closeButton.acceptsFirstMouse(for: nil))
        #expect(!closeButton.mouseDownCanMoveWindow)
        #expect(closeButton.accessibilityLabel() == "关闭贴图")
        #expect(closeButton.toolTip == "关闭贴图（Esc）")
        #expect(closeButton.accessibilityHelp()?.contains("Esc") == true)
        #expect(imageView.toolTip?.contains("Esc") == true)
        #expect(imageView.accessibilityHelp()?.contains("Esc") == true)

        controller.show()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        #expect(window.isVisible)
        #expect(window.frame == initialFrame)

        closeButton.isHidden = false
        closeButton.performClick(nil)

        #expect(closeCount == 1)
        #expect(!window.isVisible)
        #expect(!panel.allowsVisibilityRecovery)
    }

    @Test("Workspace wake restores a retained pin without activating it")
    func workspaceWakeRestoresRetainedPinWithoutActivation() async throws {
        let app = NSApplication.shared
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let manager = PinnedScreenshotManager()
        let preexistingPanels = Set(
            app.windows
                .compactMap { $0 as? PinnedScreenshotPanel }
                .map(ObjectIdentifier.init)
        )
        defer { manager.closeAll() }

        let id = try manager.pin(
            image: makeImage(width: 320, height: 180),
            anchor: CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY),
            targetScreen: screen,
            selectForKeyboard: false
        )
        let panel = try #require(
            app.windows.compactMap { $0 as? PinnedScreenshotPanel }.first {
                !preexistingPanels.contains(ObjectIdentifier($0))
            }
        )
        #expect(manager.contains(id: id))
        #expect(panel.isVisible)

        panel.orderOut(nil)
        #expect(!panel.isVisible)

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared
        )
        await Task.yield()

        #expect(panel.isVisible)
        #expect(!panel.isKeyWindow)
        #expect(panel.level == .floating)
        #expect(manager.contains(id: id))
    }

    @Test("Temporarily hidden windows restore pins in a separate idempotent batch")
    func temporarilyHiddenWindowsRestorePinsSeparately() {
        let app = NSApplication.shared
        // This suite is serialized because the production helper intentionally
        // snapshots and orders NSApp's visible windows. Preserve any pre-existing
        // test-host windows as an additional cleanup boundary.
        let preexistingVisibleWindows = app.windows.filter(\.isVisible)
        for window in preexistingVisibleWindows {
            window.orderOut(nil)
        }

        let mainWindow = NSWindow(
            contentRect: CGRect(x: 120, y: 120, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        // The fixture owns this plain NSWindow through ARC, including after
        // close(); AppKit must not independently release it on close.
        mainWindow.isReleasedWhenClosed = false
        #expect(!mainWindow.isReleasedWhenClosed)
        let firstPin = PinnedScreenshotPanel(
            contentRect: CGRect(x: 560, y: 180, width: 240, height: 120),
            sourcePixelSize: CGSize(width: 400, height: 200),
            maximumContentSize: CGSize(width: 800, height: 600)
        )
        let secondPin = PinnedScreenshotPanel(
            contentRect: CGRect(x: 820, y: 180, width: 180, height: 180),
            sourcePixelSize: CGSize(width: 300, height: 300),
            maximumContentSize: CGSize(width: 800, height: 600)
        )
        defer {
            for window in [mainWindow, firstPin, secondPin] {
                window.delegate = nil
                window.orderOut(nil)
                window.close()
            }
            for window in preexistingVisibleWindows where !window.isVisible {
                window.orderFront(nil)
            }
        }

        mainWindow.orderFront(nil)
        firstPin.orderFront(nil)
        secondPin.orderFront(nil)
        #expect(mainWindow.isVisible)
        #expect(firstPin.isVisible)
        #expect(secondPin.isVisible)

        let hiddenWindows = TemporarilyHiddenAppWindows()

        #expect(!mainWindow.isVisible)
        #expect(!firstPin.isVisible)
        #expect(!secondPin.isVisible)
        #expect(firstPin.temporaryVisibilitySuppressionDepth == 1)
        #expect(secondPin.temporaryVisibilitySuppressionDepth == 1)

        // A wake/Space recovery pass must not expose pins inside a capture.
        firstPin.recoverVisibilityAfterSystemTransition()
        secondPin.recoverVisibilityAfterSystemTransition()
        #expect(!firstPin.isVisible)
        #expect(!secondPin.isVisible)

        hiddenWindows.restorePinnedScreenshotWindows()

        #expect(!mainWindow.isVisible)
        #expect(firstPin.isVisible)
        #expect(secondPin.isVisible)
        #expect(firstPin.temporaryVisibilitySuppressionDepth == 0)
        #expect(secondPin.temporaryVisibilitySuppressionDepth == 0)

        hiddenWindows.restorePinnedScreenshotWindows()
        #expect(!mainWindow.isVisible)
        #expect(firstPin.isVisible)
        #expect(secondPin.isVisible)

        // Once pins have been split out of the pending restore batch, the final
        // main-window restore must not resurrect one the user has hidden/closed.
        firstPin.orderOut(nil)
        hiddenWindows.restore()

        #expect(mainWindow.isVisible)
        #expect(!firstPin.isVisible)
        #expect(secondPin.isVisible)

        hiddenWindows.restore()
        #expect(mainWindow.isVisible)
        #expect(!firstPin.isVisible)
        #expect(secondPin.isVisible)

        mainWindow.orderOut(nil)
        hiddenWindows.restore()
        #expect(!mainWindow.isVisible)
        #expect(!firstPin.isVisible)
        #expect(secondPin.isVisible)
    }

    @Test("Nested temporary hiding restores pins only after the final scope ends")
    func nestedTemporaryHidingRestoresAfterFinalScope() {
        let app = NSApplication.shared
        let preexistingVisibleWindows = app.windows.filter(\.isVisible)
        for window in preexistingVisibleWindows {
            window.orderOut(nil)
        }

        let pin = PinnedScreenshotPanel(
            contentRect: CGRect(x: 280, y: 180, width: 240, height: 120),
            sourcePixelSize: CGSize(width: 400, height: 200),
            maximumContentSize: CGSize(width: 800, height: 600)
        )
        defer {
            pin.close()
            for window in preexistingVisibleWindows where !window.isVisible {
                window.orderFront(nil)
            }
        }

        pin.orderFrontRegardless()
        let outerScope = TemporarilyHiddenAppWindows()
        let innerScope = TemporarilyHiddenAppWindows()

        #expect(pin.temporaryVisibilitySuppressionDepth == 2)
        #expect(!pin.isVisible)

        outerScope.restorePinnedScreenshotWindows()
        #expect(pin.temporaryVisibilitySuppressionDepth == 1)
        #expect(!pin.isVisible)

        innerScope.restorePinnedScreenshotWindows()
        #expect(pin.temporaryVisibilitySuppressionDepth == 0)
        #expect(pin.isVisible)
    }

    @Test("Explicitly closed pin cannot be revived by capture cleanup or recovery")
    func explicitCloseCannotBeRevived() {
        let app = NSApplication.shared
        let preexistingVisibleWindows = app.windows.filter(\.isVisible)
        for window in preexistingVisibleWindows {
            window.orderOut(nil)
        }

        let pin = PinnedScreenshotPanel(
            contentRect: CGRect(x: 280, y: 180, width: 240, height: 120),
            sourcePixelSize: CGSize(width: 400, height: 200),
            maximumContentSize: CGSize(width: 800, height: 600)
        )
        defer {
            for window in preexistingVisibleWindows where !window.isVisible {
                window.orderFront(nil)
            }
        }

        pin.orderFrontRegardless()
        let hiddenWindows = TemporarilyHiddenAppWindows()
        #expect(pin.temporaryVisibilitySuppressionDepth == 1)
        #expect(!pin.isVisible)

        pin.close()
        hiddenWindows.restorePinnedScreenshotWindows()
        pin.recoverVisibilityAfterSystemTransition()

        #expect(!pin.allowsVisibilityRecovery)
        #expect(pin.temporaryVisibilitySuppressionDepth == 0)
        #expect(!pin.isVisible)
    }

    @Test("Abandoned temporary hiding scope restores its visibility lease")
    func abandonedTemporaryHidingScopeRestoresPin() {
        let app = NSApplication.shared
        let preexistingVisibleWindows = app.windows.filter(\.isVisible)
        for window in preexistingVisibleWindows {
            window.orderOut(nil)
        }

        let pin = PinnedScreenshotPanel(
            contentRect: CGRect(x: 280, y: 180, width: 240, height: 120),
            sourcePixelSize: CGSize(width: 400, height: 200),
            maximumContentSize: CGSize(width: 800, height: 600)
        )
        defer {
            pin.close()
            for window in preexistingVisibleWindows where !window.isVisible {
                window.orderFront(nil)
            }
        }

        pin.orderFrontRegardless()
        var hiddenWindows: TemporarilyHiddenAppWindows? = TemporarilyHiddenAppWindows()
        #expect(hiddenWindows != nil)
        #expect(pin.temporaryVisibilitySuppressionDepth == 1)
        #expect(!pin.isVisible)

        hiddenWindows = nil

        #expect(pin.temporaryVisibilitySuppressionDepth == 0)
        #expect(pin.isVisible)
    }

    @Test("Manager retains multiple panels independently and releases budget on close")
    func managerSupportsMultiplePinsAndReleasesBudget() throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let image = try makeImage(width: 200, height: 100)
        let perImageCost = try PinnedScreenshotSnapshot(image: image).byteCost
        let manager = PinnedScreenshotManager(
            memoryBudgetBytes: perImageCost * 2
        )
        defer { manager.closeAll() }
        let anchor = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)

        let firstID = try manager.pin(image: image, anchor: anchor, targetScreen: screen)
        let secondID = try manager.pin(image: image, anchor: anchor, targetScreen: screen)

        #expect(firstID != secondID)
        #expect(manager.count == 2)
        #expect(manager.contains(id: firstID))
        #expect(manager.contains(id: secondID))
        #expect(manager.totalByteCost == perImageCost * 2)

        manager.close(id: firstID)

        #expect(manager.count == 1)
        #expect(!manager.contains(id: firstID))
        #expect(manager.contains(id: secondID))
        #expect(manager.totalByteCost == perImageCost)

        let replacementID = try manager.pin(
            image: image,
            anchor: anchor,
            targetScreen: screen
        )
        #expect(manager.count == 2)
        #expect(manager.contains(id: replacementID))
        #expect(manager.totalByteCost == perImageCost * 2)
    }

    @Test("Escape callback closes only the selected pin and immediately releases its budget")
    func escapeCallbackClosesOnlyTargetPinAndReleasesManagerBudget() throws {
        let app = NSApplication.shared
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let image = try makeImage(width: 200, height: 100)
        let perImageCost = try PinnedScreenshotSnapshot(image: image).byteCost
        let manager = PinnedScreenshotManager(
            memoryBudgetBytes: perImageCost * 2
        )
        let preexistingPanels = Set(
            app.windows
                .compactMap { $0 as? PinnedScreenshotPanel }
                .map(ObjectIdentifier.init)
        )
        defer {
            manager.closeAll()
        }
        let anchor = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)

        let firstID = try manager.pin(
            image: image,
            anchor: anchor,
            targetScreen: screen,
            selectForKeyboard: false
        )
        let firstPanel = try #require(
            app.windows.compactMap { $0 as? PinnedScreenshotPanel }.first {
                !preexistingPanels.contains(ObjectIdentifier($0))
            }
        )
        let panelsAfterFirst = preexistingPanels.union([ObjectIdentifier(firstPanel)])

        let secondID = try manager.pin(
            image: image,
            anchor: anchor,
            targetScreen: screen,
            selectForKeyboard: false
        )
        let secondPanel = try #require(
            app.windows.compactMap { $0 as? PinnedScreenshotPanel }.first {
                !panelsAfterFirst.contains(ObjectIdentifier($0))
            }
        )

        #expect(firstID != secondID)
        #expect(firstPanel !== secondPanel)
        #expect(manager.count == 2)
        #expect(manager.totalByteCost == perImageCost * 2)
        #expect(firstPanel.isVisible)
        #expect(secondPanel.isVisible)

        firstPanel.onBareEscapeClose?()

        #expect(manager.count == 1)
        #expect(manager.totalByteCost == perImageCost)
        #expect(!manager.contains(id: firstID))
        #expect(manager.contains(id: secondID))
        #expect(!firstPanel.isVisible)
        #expect(secondPanel.isVisible)
        #expect(firstPanel.onBareEscapeClose == nil)
        #expect(firstPanel.onScrollZoom == nil)
        #expect(secondPanel.onBareEscapeClose != nil)

        manager.close(id: firstID)
        #expect(manager.count == 1)
        #expect(manager.totalByteCost == perImageCost)

        let replacementID = try manager.pin(
            image: image,
            anchor: anchor,
            targetScreen: screen,
            selectForKeyboard: false
        )
        #expect(manager.count == 2)
        #expect(manager.contains(id: replacementID))
        #expect(manager.totalByteCost == perImageCost * 2)
    }

    @Test("Manager rejects a snapshot over budget without retaining a panel")
    func managerRejectsOverBudgetSnapshot() throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let image = try makeImage(width: 200, height: 100)
        let requiredCost = try PinnedScreenshotSnapshot(image: image).byteCost
        let manager = PinnedScreenshotManager(
            memoryBudgetBytes: requiredCost - 1
        )
        defer { manager.closeAll() }
        let anchor = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)

        do {
            _ = try manager.pin(image: image, anchor: anchor, targetScreen: screen)
            Issue.record("Expected the pin to exceed the configured memory budget")
        } catch PinnedScreenshotFeatureError.memoryBudgetExceeded(
            let requiredBytes,
            let availableBytes
        ) {
            #expect(requiredBytes == requiredCost)
            #expect(availableBytes == requiredCost - 1)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(manager.count == 0)
        #expect(manager.totalByteCost == 0)
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func makeKeyEvent(
        type: NSEvent.EventType = .keyDown,
        modifierFlags: NSEvent.ModifierFlags = [],
        characters: String = "\u{1B}",
        keyCode: UInt16 = 53,
        windowNumber: Int = 0,
        isARepeat: Bool = false
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: isARepeat,
            keyCode: keyCode
        ))
    }

    private func isContained(_ frame: CGRect, in visibleFrame: CGRect) -> Bool {
        let tolerance: CGFloat = 0.001
        return frame.minX >= visibleFrame.minX - tolerance
            && frame.maxX <= visibleFrame.maxX + tolerance
            && frame.minY >= visibleFrame.minY - tolerance
            && frame.maxY <= visibleFrame.maxY + tolerance
    }

    private func distance(from point: CGPoint, to frame: CGRect) -> CGFloat {
        let nearestX = min(max(point.x, frame.minX), frame.maxX)
        let nearestY = min(max(point.y, frame.minY), frame.maxY)
        return hypot(point.x - nearestX, point.y - nearestY)
    }

    private func point(in frame: CGRect, at normalizedPosition: CGPoint) -> CGPoint {
        CGPoint(
            x: frame.minX + normalizedPosition.x * frame.width,
            y: frame.minY + normalizedPosition.y * frame.height
        )
    }

    private func normalizedPosition(of point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(
            x: (point.x - frame.minX) / frame.width,
            y: (point.y - frame.minY) / frame.height
        )
    }

    private func isApproximatelyEqual(
        _ lhs: CGFloat,
        _ rhs: CGFloat,
        tolerance: CGFloat = 0.000_001
    ) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    private func pointsAreApproximatelyEqual(
        _ lhs: CGPoint,
        _ rhs: CGPoint,
        tolerance: CGFloat = 0.000_001
    ) -> Bool {
        isApproximatelyEqual(lhs.x, rhs.x, tolerance: tolerance)
            && isApproximatelyEqual(lhs.y, rhs.y, tolerance: tolerance)
    }

    private func rectsAreApproximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = 0.000_001
    ) -> Bool {
        isApproximatelyEqual(lhs.minX, rhs.minX, tolerance: tolerance)
            && isApproximatelyEqual(lhs.minY, rhs.minY, tolerance: tolerance)
            && isApproximatelyEqual(lhs.width, rhs.width, tolerance: tolerance)
            && isApproximatelyEqual(lhs.height, rhs.height, tolerance: tolerance)
    }
}
