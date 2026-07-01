import Foundation

/// A process-global budget over the GCD lanes Exhaust's concurrent runners occupy at once.
///
/// Under `swift test --parallel` every `.threads`/`.tasks` contract run and every async property or explore run funnels concurrent work onto GCD's global queue. Swift Testing schedules many test functions at once, their aggregate lane demand exceeds what a constrained CI VM can schedule, and lanes that never get a thread trip the runner's idle timeout. The gate bounds the sum of in-flight lane reservations to ``limit`` regardless of how many test functions run at once: a run acquires its lanes, holds them for its whole duration, and releases on the way out. Excess runs wait at the gate rather than piling onto GCD.
///
/// It is a budget, not a provider: GCD still hands out the actual threads. Admission is the whole effect. See `gcd-lane-admission-design.md` for the reservation accounting (async `.threads` reserves `N+1`, see ``LaneReservation``) and the call-site trace.
///
/// - Note: This is a `final class` guarding its state with an `NSCondition` rather than an `actor`, because it has a synchronous surface by requirement: the sync `.threads` entry has no async context and reaches the state through ``acquireBlocking(_:)``, and ``release(_:)`` is called from synchronous contexts. An actor's mandatory-async surface cannot serve those without bridging through a blocking await, which is the hazard the gate exists to avoid.
final class LaneGate: @unchecked Sendable {
    /// The default lane budget: half the 64-thread per-queue GCD wall, leaving headroom below it for coordinator threads and any uncounted usage.
    static let defaultLimit = 8

    /// The smallest budget that can satisfy every reservation: the largest single request is async `.threads` at `ConcurrencyLevel.max (4) + 1`.
    static let reservationFloor = 5

    /// Environment override for ``limit``, read once at init. Mirrors NIO's `NIO_SINGLETON_BLOCKING_POOL_THREAD_COUNT` convention.
    static let environmentOverrideKey = "EXHAUST_LANE_LIMIT"

    /// The process-global gate every concurrent runner acquires from.
    static let shared = LaneGate()

    /// The maximum number of lanes handed out at once. Immutable after init.
    let limit: Int

    /// The condition is the mutex for every state access and the wait/signal channel for blocking waiters.
    private let condition = NSCondition()

    /// Lanes currently available. Guarded by `condition`.
    private var free: Int

    /// Waiters in arrival order with the OLDEST at the tail, so `release` admits with `removeLast()` (O(1), FIFO) and enqueue is `insert(at: 0)` (O(n), off the admission loop, tiny n). Guarded by `condition`.
    private var waiters: [Waiter] = []

    /// One run waiting for admission. Async waiters carry a continuation resumed by ``release(_:)``; blocking waiters carry a flag box set by ``release(_:)`` and observed under the lock.
    private enum Waiter {
        case async(count: Int, continuation: CheckedContinuation<Void, Never>)
        case blocking(count: Int, flag: FlagBox)

        var count: Int {
            switch self {
                case let .async(count, _): count
                case let .blocking(count, _): count
            }
        }
    }

    /// A mutable admission flag shared between a blocking waiter and ``release(_:)``. Accessed only under the lock, so plain mutable state is safe.
    private final class FlagBox {
        var admitted = false
    }

    /// Creates a gate reading ``environmentOverrideKey`` from the environment, falling back to ``defaultLimit``.
    convenience init() {
        let resolved = ProcessInfo.processInfo.environment[Self.environmentOverrideKey].flatMap(Int.init) ?? Self.defaultLimit
        self.init(limit: resolved)
    }

    /// Creates a gate with an explicit budget, clamped up to ``reservationFloor``. Tests construct their own small-budget instances through this rather than touching ``shared``.
    init(limit: Int) {
        let clamped = max(limit, Self.reservationFloor)
        self.limit = clamped
        free = clamped
    }

    /// Suspends until `count` lanes are available, then reserves them. For the async entries, which park as a continuation holding no thread rather than blocking a GCD worker.
    ///
    /// Cancellation is not handled: a unit test is never cancelled, and the async entries reach the gate through a non-cancellable `dispatchToGCD` hop, so a parked continuation is always eventually resumed on admission.
    func acquire(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            condition.lock()
            // Enqueue-under-the-lock closes the lost-wakeup race: the check and the enqueue are atomic against a concurrent `release`.
            if waiters.isEmpty, free >= count {
                free -= count
                condition.unlock()
                continuation.resume()
            } else {
                waiters.insert(.async(count: count, continuation: continuation), at: 0)
                condition.unlock()
            }
        }
    }

    /// Blocks the calling thread until `count` lanes are available, then reserves them. For the sync `.threads` entry, which has no async context and already occupies its thread for the whole run.
    func acquireBlocking(_ count: Int) {
        condition.lock()
        defer { condition.unlock() }
        if waiters.isEmpty, free >= count {
            free -= count
            return
        }
        let flag = FlagBox()
        waiters.insert(.blocking(count: count, flag: flag), at: 0)
        while flag.admitted == false {
            condition.wait()
        }
    }

    /// Returns `count` lanes to the budget and admits as many waiting runs as now fit, in FIFO order.
    ///
    /// Admission stops at the first waiter that does not fit, so a large request holds the line against later small ones. Async continuations are resumed outside the lock; blocking waiters are woken by a single broadcast.
    func release(_ count: Int) {
        var resumptions: [CheckedContinuation<Void, Never>] = []
        var wokeBlocking = false
        condition.lock()
        free += count
        while let head = waiters.last, free >= head.count {
            waiters.removeLast()
            free -= head.count
            switch head {
                case let .async(_, continuation):
                    resumptions.append(continuation)
                case let .blocking(_, flag):
                    flag.admitted = true
                    wokeBlocking = true
            }
        }
        if wokeBlocking {
            condition.broadcast()
        }
        condition.unlock()
        for continuation in resumptions {
            continuation.resume()
        }
    }

    /// Reserves `count` lanes, runs `body`, and releases them, blocking the caller for admission. The synchronous counterpart to `dispatchToGCD(reserving:)` for the sync `.threads` entry.
    func withLanesBlocking<Result>(_ count: Int, _ body: () -> Result) -> Result {
        acquireBlocking(count)
        defer { release(count) }
        return body()
    }
}

// MARK: - Test Introspection

extension LaneGate {
    /// Lanes currently available. For tests asserting the atomic-`N` accounting.
    var freeCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return free
    }

    /// Number of runs waiting for admission. For tests that must observe a waiter has parked before proceeding.
    var waiterCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return waiters.count
    }
}

// MARK: - Reservation Sizes

/// The lane count each concurrent entry reserves from the ``LaneGate``.
///
/// Centralized so the `+1` on the async `.threads` path lives in one commented place rather than as a magic number at each dispatch site.
enum LaneReservation {
    /// The async `.threads` reservation: one lane per concurrency level, plus one for the coordinator GCD worker parked on `group.wait` while the level lanes run.
    static func asyncThreads(_ level: Int) -> Int {
        level + 1
    }

    /// The sync `.threads` reservation: one lane per concurrency level. Its coordinator runs inline on the caller's thread via `global().sync`, off the GCD budget, so no `+1`.
    static func syncThreads(_ level: Int) -> Int {
        level
    }

    /// The reservation for a run with no lane fan-out: cooperative `.tasks`, the sequential-async contract, and async `#exhaust`/`#explore`, which occupy a single coordinator worker.
    static let single = 1
}
