import AppKit
import Foundation

/// Coordinates clipboard-history observation with short-lived pasteboard
/// transactions that must never become history entries.
///
/// The selected-text fallback temporarily copies another application's
/// selection and then restores the user's previous pasteboard. A pasteboard
/// cannot identify its writer, so the complete transaction is hidden from the
/// history observer instead of trying to distinguish its intermediate values.
@MainActor
final class ClipboardHistoryObservationGate {
    typealias UptimeProvider = @MainActor @Sendable () -> UInt64

    struct Lease: Hashable, Sendable {
        fileprivate let id: UUID
    }

    struct Observation: Equatable, Sendable {
        let epoch: UInt64
        let isSuppressed: Bool
    }

    private var activeLeaseIDs: Set<UUID> = []
    private var activeTransactionMayReceiveDelayedWrite = false
    private var ignoredSettledChangeCount: Int?
    private var delayedWriteSuppression: DelayedWriteSuppression?
    private let delayedWriteQuietPeriodNanoseconds: UInt64
    private let uptimeProvider: UptimeProvider
    private(set) var epoch: UInt64 = 0

    private struct DelayedWriteSuppression {
        var lastSuppressedChangeCount: Int
        let quietUntil: UInt64
    }

    init(
        delayedWriteQuietPeriodNanoseconds: UInt64 = 5_000_000_000,
        uptimeProvider: @escaping UptimeProvider = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.delayedWriteQuietPeriodNanoseconds = delayedWriteQuietPeriodNanoseconds
        self.uptimeProvider = uptimeProvider
    }

    var observation: Observation {
        Observation(epoch: epoch, isSuppressed: !activeLeaseIDs.isEmpty)
    }

    func beginSuppression() -> Lease {
        epoch &+= 1
        let lease = Lease(id: UUID())
        if activeLeaseIDs.isEmpty {
            activeTransactionMayReceiveDelayedWrite = false
        }
        activeLeaseIDs.insert(lease.id)
        ignoredSettledChangeCount = nil
        return lease
    }

    func finishSuppression(
        _ lease: Lease,
        settledChangeCount: Int,
        mayReceiveDelayedWrite: Bool = false
    ) {
        guard activeLeaseIDs.remove(lease.id) != nil else { return }
        activeTransactionMayReceiveDelayedWrite =
            activeTransactionMayReceiveDelayedWrite || mayReceiveDelayedWrite
        epoch &+= 1
        if activeLeaseIDs.isEmpty {
            if activeTransactionMayReceiveDelayedWrite {
                let now = uptimeProvider()
                delayedWriteSuppression = DelayedWriteSuppression(
                    lastSuppressedChangeCount: settledChangeCount,
                    quietUntil: addingWithoutOverflow(
                        delayedWriteQuietPeriodNanoseconds,
                        to: now
                    )
                )
                ignoredSettledChangeCount = nil
            } else if var delayedWriteSuppression {
                // A synchronous OnePaw copy (for example, copying a share link
                // or a history item) must not erase an earlier quick-copy
                // quarantine that is still waiting for a delayed target write.
                delayedWriteSuppression.lastSuppressedChangeCount = settledChangeCount
                self.delayedWriteSuppression = delayedWriteSuppression
                ignoredSettledChangeCount = nil
            } else {
                ignoredSettledChangeCount = settledChangeCount
            }
            activeTransactionMayReceiveDelayedWrite = false
        }
    }

    /// Returns whether the observer should ignore the current pasteboard
    /// generation. The settled generation is consumed once; if a real copy
    /// wins the race after suppression ends, its newer generation is retained.
    func shouldSuppress(changeCount: Int) -> Bool {
        guard activeLeaseIDs.isEmpty else { return true }

        if var delayedWriteSuppression {
            if changeCount == delayedWriteSuppression.lastSuppressedChangeCount {
                if uptimeProvider() > delayedWriteSuppression.quietUntil {
                    self.delayedWriteSuppression = nil
                }
                return true
            }

            let now = uptimeProvider()
            if now <= delayedWriteSuppression.quietUntil {
                delayedWriteSuppression.lastSuppressedChangeCount = changeCount
                self.delayedWriteSuppression = delayedWriteSuppression
                return true
            }

            // Clipboard writers are not identifiable. Keep the ambiguity
            // window bounded so a failed quick translation never discards an
            // unrelated user copy minutes or hours later.
            self.delayedWriteSuppression = nil
        }

        guard let ignoredSettledChangeCount else { return false }
        self.ignoredSettledChangeCount = nil
        return changeCount == ignoredSettledChangeCount
    }

    func canCommit(observation: Observation) -> Bool {
        activeLeaseIDs.isEmpty
            && delayedWriteSuppression == nil
            && observation.epoch == epoch
    }

    @discardableResult
    func performSuppressedWrite<T>(
        to pasteboard: NSPasteboard,
        _ body: () throws -> T
    ) rethrows -> T {
        let lease = beginSuppression()
        defer {
            finishSuppression(lease, settledChangeCount: pasteboard.changeCount)
        }
        return try body()
    }

    private func addingWithoutOverflow(_ value: UInt64, to base: UInt64) -> UInt64 {
        let (result, overflow) = base.addingReportingOverflow(value)
        return overflow ? UInt64.max : result
    }
}
