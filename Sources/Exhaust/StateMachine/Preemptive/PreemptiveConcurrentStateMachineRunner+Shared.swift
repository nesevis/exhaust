// Shared types for the synchronous and async preemptive spec runners.
import ExhaustCore
import Foundation
import IssueReporting

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(WinSDK)
    import WinSDK
#endif

/// Groups shared types for the synchronous and async preemptive spec runners.
enum Preemptive {
    /// Captures the result of one preemptive concurrent execution probe.
    enum Outcome<Spec: StateMachineSpecBase> {
        /// The execution is consistent with some valid sequential ordering.
        case passed
        /// A lane or the drain loop did not finish within the idle timeout.
        case timedOut(concurrentSpec: Spec?)
        /// A command threw, an invariant failed, or an ObjC exception was caught before response comparison.
        case failed(concurrentSpec: Spec?)
        /// The oracle detected a state divergence from the sequential reference. Per-lane observed responses are available for linearizability analysis.
        case oracleMismatch(laneResponses: [[ObservedResponse<Spec.Command>]], concurrentSpec: Spec)

        var concurrentSpec: Spec? {
            switch self {
                case .passed: nil
                case let .timedOut(concurrentSpec): concurrentSpec
                case let .failed(concurrentSpec): concurrentSpec
                case let .oracleMismatch(_, concurrentSpec): concurrentSpec
            }
        }

        var laneResponses: [[ObservedResponse<Spec.Command>]]? {
            switch self {
                case let .oracleMismatch(laneResponses, _): laneResponses
                default: nil
            }
        }
    }
}

// MARK: - Lane Start Rendezvous

/// Aligns the lanes' first commands in real time with a bounded spin barrier.
///
/// The lanes are dispatched as independent GCD blocks, and a lane's whole command list often completes in microseconds. On an otherwise idle machine (a small CI VM running `swift test --no-parallel` is the observed case), GCD worker wakeup skew can exceed a lane's entire runtime, so the "concurrent" phase degenerates to back-to-back sequential execution and no probe in the budget can observe a race. Each lane arrives here before its first command and spins until every lane has arrived, so the lanes depart within one polling iteration of each other no matter how staggered their threads woke up.
///
/// The wait is bounded by the spin budget: a lane whose siblings never arrive proceeds alone, degrading to the unsynchronized behavior instead of stalling the probe when a sibling's thread is starved (the constrained-runner case the ``LaneGate`` documentation describes). The wait polls rather than blocks on purpose, because a blocking primitive would reintroduce the very wakeup skew the barrier exists to remove. After ``pureSpinNanoseconds`` each poll sleeps briefly instead of spinning on. The sleep, not a yield, is load-bearing: a hot unlock-relock loop starves the barrier's own lock on Linux (an unfair futex lets the relock win against a blocked arriver indefinitely, and `sched_yield` does not hand off to a futex waiter), so a yielding waiter kept the releasing arrival from ever registering and departed only by budget expiry. Sleeping leaves the lock quiescent for a full quantum, so an arriving lane acquires it on the first try.
final class LaneRendezvous: @unchecked Sendable {
    /// Upper bound on the wait for sibling lanes. Sized to cover a GCD worker spawn on a cold pool (hundreds of microseconds) with margin, and kept small because an environment whose lanes cannot run concurrently pays it once per waiting lane per probe.
    static let defaultSpinBudgetNanoseconds: UInt64 = 5_000_000

    /// How long a waiting lane polls without sleeping. Wakeup skew between already-running workers resolves well within this window, and not sleeping keeps the departure skew at nanoseconds.
    static let pureSpinNanoseconds: UInt64 = 100_000

    /// How long each poll sleeps once the pure-spin window is over. Bounds the slow path's release latency (pure-spin window plus one quantum) while keeping the lock free for arriving lanes; see the type documentation for why the waiter must sleep rather than yield.
    static let slowPathSleepMicroseconds: UInt32 = 50

    private let laneCount: Int
    private let spinBudgetNanoseconds: UInt64
    private let lock = NSLock()

    /// Lanes that have reached the barrier. Guarded by `lock`.
    private var arrivedCount = 0

    /// Creates a barrier for `laneCount` lanes. Tests pass an explicit `spinBudgetNanoseconds` (tiny to exercise the give-up path, huge to make release-by-arrival unambiguous); the runners use the default.
    init(laneCount: Int, spinBudgetNanoseconds: UInt64 = LaneRendezvous.defaultSpinBudgetNanoseconds) {
        self.laneCount = laneCount
        self.spinBudgetNanoseconds = spinBudgetNanoseconds
    }

    /// Marks the calling lane as ready, then waits until every lane is or the spin budget is exhausted.
    ///
    /// The last lane to arrive returns immediately, so at least one lane always makes progress even if the others' polling is delayed.
    func arriveAndWait() {
        lock.lock()
        arrivedCount += 1
        let allArrived = arrivedCount >= laneCount
        lock.unlock()
        if allArrived {
            return
        }
        let start = DispatchTime.now().uptimeNanoseconds
        while true {
            lock.lock()
            let complete = arrivedCount >= laneCount
            lock.unlock()
            if complete {
                return
            }
            let waited = DispatchTime.now().uptimeNanoseconds - start
            if waited >= spinBudgetNanoseconds {
                return
            }
            if waited >= Self.pureSpinNanoseconds {
                #if canImport(WinSDK)
                    Sleep(DWORD(Self.slowPathSleepMicroseconds) / 1000 + 1)
                #else
                    usleep(Self.slowPathSleepMicroseconds)
                #endif
            }
        }
    }
}

// MARK: - Test Introspection

extension LaneRendezvous {
    /// Lanes that have reached the barrier. For tests that must observe a sibling has arrived before acting.
    var arrivedLaneCount: Int {
        lock.withLocking { arrivedCount }
    }
}

// MARK: - Realized Completion Order

/// Merges per-lane observations into the order the commands actually returned, by ascending return timestamp.
///
/// This replaces the shared, locked completion log the lanes used to append to: a lock on the command path serializes the lanes between commands, and lock acquisition order can itself invert the true return order under contention. Sorting post-hoc on the per-command timestamps has neither problem. Observations without an interval sort last; the runners always record intervals, so that arm is defensive.
func realizedCompletionOrder<Command>(
    of laneResponses: [[ObservedResponse<Command>]]
) -> [ObservedResponse<Command>] {
    laneResponses
        .joined()
        .sorted { ($0.interval?.returnTime ?? .max) < ($1.interval?.returnTime ?? .max) }
}

// MARK: - Response Matching

/// Whether a replayed command result matches an observed response, using the same rule as ``LinearizabilityChecker``: skip flags must agree, and non-skipped return values must be structurally equal. Shared by the synchronous and async preemptive witness checks so the cheap realized-order replay and the full interleaving search never disagree on what "the same response" means.
func preemptiveResponseMatches(
    observed: ObservedOutcome,
    replayValue: Any?,
    replaySkipped: Bool
) -> Bool {
    if observed.isSkipped != replaySkipped {
        return false
    }
    switch (observed.returnValue, replayValue) {
        case (nil, nil):
            return true
        case let (observedValue?, replayedValue?):
            return structurallyEqual(observedValue, replayedValue)
        default:
            return false
    }
}
