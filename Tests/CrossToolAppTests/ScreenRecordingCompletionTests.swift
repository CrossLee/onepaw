import Foundation
import Testing
@testable import CrossToolApp

@Suite("Screen recording completion")
struct ScreenRecordingCompletionTests {
    @Test("A successful operation opens its directory at most once")
    func successfulOperationOpensDirectoryOnce() {
        var gate = RecordingCompletionDirectoryOpenGate()
        let operationID = UUID()
        let directory = URL(fileURLWithPath: "/tmp/OnePaw Recordings", isDirectory: true)
        var openedDirectories: [URL] = []
        gate.beginOperation(operationID)

        let firstResult = gate.openAfterSuccessfulCompletion(
            operationID: operationID,
            recordingsDirectory: directory
        ) { openedDirectory in
            openedDirectories.append(openedDirectory)
            return true
        }
        let duplicateResult = gate.openAfterSuccessfulCompletion(
            operationID: operationID,
            recordingsDirectory: directory
        ) { openedDirectory in
            openedDirectories.append(openedDirectory)
            return true
        }

        #expect(firstResult == .opened)
        #expect(duplicateResult == .skipped)
        #expect(openedDirectories == [directory])
    }

    @Test("Termination suppression applies only to the current operation")
    func terminationSuppressionResetsForNextOperation() {
        var gate = RecordingCompletionDirectoryOpenGate()
        let quittingOperationID = UUID()
        let nextOperationID = UUID()
        let directory = URL(fileURLWithPath: "/tmp/OnePaw Recordings", isDirectory: true)
        var openCount = 0

        gate.beginOperation(quittingOperationID)
        gate.suppressAutomaticOpen(for: quittingOperationID)
        let suppressedResult = gate.openAfterSuccessfulCompletion(
            operationID: quittingOperationID,
            recordingsDirectory: directory
        ) { _ in
            openCount += 1
            return true
        }

        gate.beginOperation(nextOperationID)
        let nextResult = gate.openAfterSuccessfulCompletion(
            operationID: nextOperationID,
            recordingsDirectory: directory
        ) { _ in
            openCount += 1
            return true
        }

        #expect(suppressedResult == .skipped)
        #expect(nextResult == .opened)
        #expect(openCount == 1)
    }

    @Test("A rejected termination restores automatic opening")
    func rejectedTerminationRestoresAutomaticOpening() {
        var gate = RecordingCompletionDirectoryOpenGate()
        let operationID = UUID()
        var openCount = 0

        gate.beginOperation(operationID)
        gate.suppressAutomaticOpen(for: operationID)
        gate.resumeAutomaticOpen(for: operationID)

        let result = gate.openAfterSuccessfulCompletion(
            operationID: operationID,
            recordingsDirectory: URL(fileURLWithPath: "/tmp/onepaw-recordings"),
            using: { _ in
                openCount += 1
                return true
            }
        )

        #expect(result == .opened)
        #expect(openCount == 1)
    }

    @Test("A Finder failure is reported once without retrying")
    func finderFailureDoesNotRetry() {
        var gate = RecordingCompletionDirectoryOpenGate()
        let operationID = UUID()
        let directory = URL(fileURLWithPath: "/tmp/OnePaw Recordings", isDirectory: true)
        var openCount = 0
        gate.beginOperation(operationID)

        let failedResult = gate.openAfterSuccessfulCompletion(
            operationID: operationID,
            recordingsDirectory: directory
        ) { _ in
            openCount += 1
            return false
        }
        let duplicateResult = gate.openAfterSuccessfulCompletion(
            operationID: operationID,
            recordingsDirectory: directory
        ) { _ in
            openCount += 1
            return true
        }

        #expect(failedResult == .failed)
        #expect(duplicateResult == .skipped)
        #expect(openCount == 1)
    }

    @Test("A callback for another operation cannot open Finder")
    func staleOperationCannotOpenDirectory() {
        var gate = RecordingCompletionDirectoryOpenGate()
        let currentOperationID = UUID()
        let staleOperationID = UUID()
        let directory = URL(fileURLWithPath: "/tmp/OnePaw Recordings", isDirectory: true)
        var didOpen = false
        gate.beginOperation(currentOperationID)

        let result = gate.openAfterSuccessfulCompletion(
            operationID: staleOperationID,
            recordingsDirectory: directory
        ) { _ in
            didOpen = true
            return true
        }

        #expect(result == .skipped)
        #expect(!didOpen)
    }
}
