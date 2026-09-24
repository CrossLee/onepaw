import Foundation
import Testing
@testable import CrossToolApp

@Test func quickTranslationDirectionRecognizesChineseEnglishAndMixedText() {
    #expect(
        QuickTranslationDirectionResolver.direction(for: "你好，欢迎使用一爪")
            == .chineseToEnglish
    )
    #expect(
        QuickTranslationDirectionResolver.direction(for: "Hello, welcome to OnePaw.")
            == .englishToChinese
    )
    #expect(
        QuickTranslationDirectionResolver.direction(for: "一爪快捷翻译")
            == .chineseToEnglish
    )
    #expect(QuickTranslationDirectionResolver.direction(for: " 123… ") == nil)
}

@Test func quickTranslationDirectionsUseStableChineseAndEnglishIdentifiers() {
    #expect(QuickTranslationDirection.chineseToEnglish.sourceLanguageIdentifier == "zh-Hans")
    #expect(QuickTranslationDirection.chineseToEnglish.targetLanguageIdentifier == "en")
    #expect(QuickTranslationDirection.englishToChinese.sourceLanguageIdentifier == "en")
    #expect(QuickTranslationDirection.englishToChinese.targetLanguageIdentifier == "zh-Hans")
}

@Test func accessibilityAncestorWalkerTraversesBeyondEightLevels() {
    var visited: [Int] = []

    let termination = AccessibilityAncestorWalker.walk(
        from: 0,
        shouldContinue: { true },
        isSameNode: ==,
        visit: { node in
            visited.append(node)
            return .continueTraversal
        },
        parent: { node in
            node < 11 ? node + 1 : nil
        }
    )

    #expect(visited == Array(0 ... 11))
    #expect(termination == .exhausted)
}

@Test func accessibilityAncestorWalkerStopsWhenItDetectsAParentCycle() {
    var visited: [Int] = []

    let termination = AccessibilityAncestorWalker.walk(
        from: 0,
        shouldContinue: { true },
        isSameNode: ==,
        visit: { node in
            visited.append(node)
            return .continueTraversal
        },
        parent: { node in
            switch node {
            case 0: 1
            case 1: 2
            default: 1
            }
        }
    )

    #expect(visited == [0, 1, 2])
    #expect(termination == .cycleDetected)
}

@Test func accessibilityAncestorWalkerHonorsInterruption() {
    var visited: [Int] = []
    var continuationChecksRemaining = 5

    let termination = AccessibilityAncestorWalker.walk(
        from: 0,
        shouldContinue: {
            defer { continuationChecksRemaining -= 1 }
            return continuationChecksRemaining > 0
        },
        isSameNode: ==,
        visit: { node in
            visited.append(node)
            return .continueTraversal
        },
        parent: { $0 + 1 }
    )

    #expect(visited == [0, 1, 2])
    #expect(termination == .interrupted)
}

@Test func accessibilitySecurityChainRequiresTheExactAncestor() {
    let parents = [0: 1, 1: 2, 2: 3]

    let valid = AccessibilitySecurityChainValidator.state(
        from: 0,
        through: 2,
        shouldContinue: { true },
        isSameNode: ==,
        inspect: { _ in .notSecure },
        parent: { parents[$0] }
    )
    let wrongOwner = AccessibilitySecurityChainValidator.state(
        from: 0,
        through: 9,
        shouldContinue: { true },
        isSameNode: ==,
        inspect: { _ in .notSecure },
        parent: { parents[$0] }
    )
    let secureInspector: (Int) -> SecureInputState = { node in
        node == 1 ? .secure : .notSecure
    }
    let secureBeforeOwner: SecureInputState = AccessibilitySecurityChainValidator.state(
        from: 0,
        through: 2,
        shouldContinue: { true },
        isSameNode: ==,
        inspect: secureInspector,
        parent: { parents[$0] }
    )

    #expect(valid == .notSecure)
    #expect(wrongOwner == .unknown)
    #expect(secureBeforeOwner == .secure)
}

@Test func accessibilityUniqueSelectionRejectsASecondCandidate() {
    var selection = AccessibilityUniqueSelection<String>()

    let acceptedFirst = selection.record("first")
    #expect(acceptedFirst)
    #expect(selection.value == "first")
    let acceptedSecond = selection.record("second")
    #expect(!acceptedSecond)
    #expect(selection.value == nil)
    #expect(selection.isAmbiguous)
}

@Test func accessibilityDescendantWalkerTraversesTheCompleteTreeBreadthFirst() {
    let childrenByNode = [
        0: [1, 2],
        1: [3],
        2: [4, 5],
        3: [],
        4: [],
        5: [0]
    ]
    var visited: [Int] = []

    let termination = AccessibilityDescendantWalker.walk(
        from: 0,
        maximumNodeCount: 16,
        shouldContinue: { true },
        isSameNode: ==,
        visit: { node in
            visited.append(node)
            return .continueTraversal
        },
        children: { .children(childrenByNode[$0] ?? []) }
    )

    #expect(visited == [0, 1, 2, 3, 4, 5])
    #expect(termination == .exhausted)
}

@Test func accessibilityDescendantWalkerFailsClosedOnChildReadFailure() {
    let termination = AccessibilityDescendantWalker.walk(
        from: 0,
        maximumNodeCount: 16,
        shouldContinue: { true },
        isSameNode: ==,
        visit: { _ in .continueTraversal },
        children: { node in
            node == 0 ? .children([1]) : .fail
        }
    )

    #expect(termination == .failed)
}

@Test func accessibilityDescendantWalkerEnforcesItsNodeLimit() {
    let termination = AccessibilityDescendantWalker.walk(
        from: 0,
        maximumNodeCount: 3,
        shouldContinue: { true },
        isSameNode: ==,
        visit: { _ in .continueTraversal },
        children: { node in
            node == 0 ? .children([1, 2, 3]) : .children([])
        }
    )

    #expect(termination == .nodeLimitExceeded)
}

@Test func accessibilityDescendantWalkerPropagatesChildCountLimit() {
    let termination = AccessibilityDescendantWalker.walk(
        from: 0,
        maximumNodeCount: 3,
        shouldContinue: { true },
        isSameNode: ==,
        visit: { _ in .continueTraversal },
        children: { _ in .nodeLimitExceeded }
    )

    #expect(termination == .nodeLimitExceeded)
}

@MainActor
@Test func selectedTextCapturePromptsAndDoesNotReadWithoutAccessibilityPermission() async {
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var prompts = 0
        private var reads = 0
        private var fallbacks = 0

        func recordPrompt() { lock.withLock { prompts += 1 } }
        func recordRead() { lock.withLock { reads += 1 } }
        func recordFallback() { lock.withLock { fallbacks += 1 } }
        var snapshot: (prompts: Int, reads: Int, fallbacks: Int) {
            lock.withLock { (prompts, reads, fallbacks) }
        }
    }

    let probe = Probe()
    let service = SelectedTextCaptureService(
        trustChecker: { false },
        permissionRequester: { probe.recordPrompt() },
        targetValidator: { _ in true },
        secureInputChecker: { _ in .notSecure },
        selectionReader: { _ in
            probe.recordRead()
            return .selected("should not be read")
        },
        fallbackReader: { _ in
            probe.recordFallback()
            return .selected("should not be copied")
        }
    )

    let result = await service.capture(applicationPID: 42)
    #expect(result == .permissionRequired)
    #expect(probe.snapshot.prompts == 1)
    #expect(probe.snapshot.reads == 0)
    #expect(probe.snapshot.fallbacks == 0)
}

@MainActor
@Test func selectedTextCaptureUsesAccessibilityWithoutClipboardFallback() async {
    final class Probe {
        var fallbackCount = 0
    }

    let probe = Probe()
    let service = SelectedTextCaptureService(
        trustChecker: { true },
        permissionRequester: {},
        targetValidator: { _ in true },
        secureInputChecker: { _ in .notSecure },
        selectionReader: { _ in .selected("AX selection") },
        fallbackReader: { _ in
            probe.fallbackCount += 1
            return .selected("clipboard selection")
        }
    )

    let result = await service.capture(applicationPID: 42)

    #expect(result == .selected("AX selection"))
    #expect(probe.fallbackCount == 0)
}

@MainActor
@Test func selectedTextCaptureFallsBackWhenAccessibilityCannotExposeSelection() async {
    let service = SelectedTextCaptureService(
        trustChecker: { true },
        permissionRequester: {},
        targetValidator: { _ in true },
        secureInputChecker: { _ in .notSecure },
        selectionReader: { _ in .unavailable },
        fallbackReader: { _ in .selected("Browser selection") }
    )

    let result = await service.capture(applicationPID: 42)

    #expect(result == .selected("Browser selection"))
}

@MainActor
@Test func selectedTextCaptureFallsBackWhenAccessibilityReportsNoSelection() async {
    let service = SelectedTextCaptureService(
        trustChecker: { true },
        permissionRequester: {},
        targetValidator: { _ in true },
        secureInputChecker: { _ in .notSecure },
        selectionReader: { _ in .noSelection },
        fallbackReader: { _ in .selected("Custom editor selection") }
    )

    let result = await service.capture(applicationPID: 42)

    #expect(result == .selected("Custom editor selection"))
}

@MainActor
@Test func selectedTextCaptureUsesValidatedMarkersWhenFocusSecurityIsUnknown() async {
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var selectionReads = 0
        private var markerReads = 0
        private var fallbacks = 0

        func recordSelectionRead() { lock.withLock { selectionReads += 1 } }
        func recordMarkerRead() { lock.withLock { markerReads += 1 } }
        func recordFallback() { lock.withLock { fallbacks += 1 } }
        var snapshot: (selectionReads: Int, markerReads: Int, fallbacks: Int) {
            lock.withLock { (selectionReads, markerReads, fallbacks) }
        }
    }

    let probe = Probe()
    let service = SelectedTextCaptureService(
        trustChecker: { true },
        permissionRequester: {},
        targetValidator: { _ in true },
        secureInputChecker: { _ in .unknown },
        selectionReader: { _ in
            probe.recordSelectionRead()
            return .selected("unvalidated text")
        },
        markerSelectionReader: { _ in
            probe.recordMarkerRead()
            return .selected("validated Codex selection")
        },
        fallbackReader: { _ in
            probe.recordFallback()
            return .selected("clipboard text")
        }
    )

    let result = await service.capture(applicationPID: 42)

    #expect(result == .selected("validated Codex selection"))
    #expect(probe.snapshot.selectionReads == 0)
    #expect(probe.snapshot.markerReads == 1)
    #expect(probe.snapshot.fallbacks == 0)
}

@MainActor
@Test func selectedTextCaptureNeverCopiesWhenUnknownMarkerReadFails() async {
    final class Probe {
        var fallbackCount = 0
    }

    let probe = Probe()
    let service = SelectedTextCaptureService(
        trustChecker: { true },
        permissionRequester: {},
        targetValidator: { _ in true },
        secureInputChecker: { _ in .unknown },
        selectionReader: { _ in .selected("unvalidated text") },
        markerSelectionReader: { _ in .unavailable },
        fallbackReader: { _ in
            probe.fallbackCount += 1
            return .selected("must not be copied")
        }
    )

    let result = await service.capture(applicationPID: 42)

    #expect(result == .unavailable)
    #expect(probe.fallbackCount == 0)
}

@MainActor
@Test func selectedTextCaptureMapsSecureFallbackWithoutReturningText() async {
    let service = SelectedTextCaptureService(
        trustChecker: { true },
        permissionRequester: {},
        targetValidator: { _ in true },
        secureInputChecker: { _ in .notSecure },
        selectionReader: { _ in .unavailable },
        fallbackReader: { _ in .secureInput }
    )

    let result = await service.capture(applicationPID: 42)

    #expect(result == .secureInput)
}

@MainActor
@Test func selectedTextCaptureReportsClipboardRestoreFailurePrecisely() async {
    let service = SelectedTextCaptureService(
        trustChecker: { true },
        permissionRequester: {},
        targetValidator: { _ in true },
        secureInputChecker: { _ in .notSecure },
        selectionReader: { _ in .unavailable },
        fallbackReader: { _ in .restoreFailed }
    )

    let result = await service.capture(applicationPID: 42)

    #expect(result == .clipboardRestoreFailed)
}

@MainActor
@Test func selectedTextCaptureDoesNotReadAccessibilityInsideSecureInput() async {
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        private var fallbacks = 0

        func recordRead() { lock.withLock { reads += 1 } }
        func recordFallback() { lock.withLock { fallbacks += 1 } }
        var snapshot: (reads: Int, fallbacks: Int) {
            lock.withLock { (reads, fallbacks) }
        }
    }

    let probe = Probe()
    let service = SelectedTextCaptureService(
        trustChecker: { true },
        permissionRequester: {},
        targetValidator: { _ in true },
        secureInputChecker: { _ in .secure },
        selectionReader: { _ in
            probe.recordRead()
            return .selected("must not be read")
        },
        fallbackReader: { _ in
            probe.recordFallback()
            return .selected("must not be copied")
        }
    )

    let result = await service.capture(applicationPID: 42)

    #expect(result == .secureInput)
    #expect(probe.snapshot.reads == 0)
    #expect(probe.snapshot.fallbacks == 0)
}

@MainActor
@Test func selectedTextCaptureDiscardsAXResultAfterTargetAppChanges() async {
    final class Probe {
        var validationCount = 0
        var fallbackCount = 0
    }

    let probe = Probe()
    let service = SelectedTextCaptureService(
        trustChecker: { true },
        permissionRequester: {},
        targetValidator: { _ in
            probe.validationCount += 1
            return probe.validationCount <= 2
        },
        secureInputChecker: { _ in .notSecure },
        selectionReader: { _ in .selected("stale selection") },
        fallbackReader: { _ in
            probe.fallbackCount += 1
            return .selected("must not run")
        }
    )

    let result = await service.capture(applicationPID: 42)

    #expect(result == .targetChanged)
    #expect(probe.fallbackCount == 0)
}

@MainActor
@Test func selectedTextCaptureReturnsCancelledAfterBlockedAXReadFinishes() async {
    final class BlockingReader: @unchecked Sendable {
        private let lock = NSLock()
        private let releaseSemaphore = DispatchSemaphore(value: 0)
        private var didStart = false

        var hasStarted: Bool {
            lock.withLock { didStart }
        }

        func read() -> SelectedTextCaptureResult {
            lock.withLock { didStart = true }
            releaseSemaphore.wait()
            return .selected("stale selection")
        }

        func release() {
            releaseSemaphore.signal()
        }
    }

    let reader = BlockingReader()
    let service = SelectedTextCaptureService(
        trustChecker: { true },
        permissionRequester: {},
        targetValidator: { _ in true },
        secureInputChecker: { _ in .notSecure },
        selectionReader: { _ in reader.read() },
        fallbackReader: { _ in .selected("must not run") }
    )
    let task = Task { @MainActor in
        await service.capture(applicationPID: 42)
    }

    while !reader.hasStarted {
        await Task.yield()
    }
    task.cancel()
    reader.release()

    #expect(await task.value == .cancelled)
}

@available(macOS 15.0, *)
@MainActor
@Test func quickTranslationPreparesInputDirectionAndSupportedPair() async throws {
    let suiteName = "quick-translation-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let english = Locale.Language(identifier: "en")
    let chinese = Locale.Language(identifier: "zh-Hans")
    let model = TranslationFeatureModel(
        defaults: defaults,
        supportedLanguageLoader: { [english, chinese] },
        pairAvailabilityLoader: { _, _ in .supported }
    )
    await model.loadSupportedLanguagesIfNeeded()

    let prepared = await model.prepareQuickTranslation(
        text: "Hello from another app.",
        direction: .englishToChinese
    )

    #expect(prepared)
    #expect(model.inputText == "Hello from another app.")
    #expect(model.sourceLanguage?.isEquivalent(to: english) == true)
    #expect(model.targetLanguage?.isEquivalent(to: chinese) == true)
    #expect(model.pairValidationState.status == .supported)
    #expect(model.canTranslate)
}

@available(macOS 15.0, *)
@MainActor
@Test func quickTranslationStagesInputBeforeLanguageLoadingCompletes() throws {
    let suiteName = "quick-translation-stage-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let model = TranslationFeatureModel(
        defaults: defaults,
        supportedLanguageLoader: { [] },
        pairAvailabilityLoader: { _, _ in .unsupported }
    )

    model.stageQuickTranslationInput("Text visible immediately")

    #expect(model.inputText == "Text visible immediately")
    #expect(model.outputText.isEmpty)
}

@available(macOS 15.0, *)
@MainActor
@Test func quickTranslationFallsBackToAnAvailableEnglishRegion() async throws {
    let suiteName = "quick-translation-region-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let britishEnglish = Locale.Language(identifier: "en-GB")
    let chinese = Locale.Language(identifier: "zh-Hans")
    let model = TranslationFeatureModel(
        defaults: defaults,
        supportedLanguageLoader: { [britishEnglish, chinese] },
        pairAvailabilityLoader: { _, _ in .supported }
    )
    await model.loadSupportedLanguagesIfNeeded()

    let prepared = await model.prepareQuickTranslation(
        text: "Hello from another app.",
        direction: .englishToChinese
    )

    #expect(prepared)
    #expect(model.sourceLanguage?.minimalIdentifier == britishEnglish.minimalIdentifier)
    #expect(model.targetLanguage?.isEquivalent(to: chinese) == true)
}
