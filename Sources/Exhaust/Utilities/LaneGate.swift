import Foundation

/// A process-global budget over the GCD lanes Exhaust's concurrent runners occupy at once.
///
/// Under `swift test --parallel` the async concurrent runs — async `.threads`/`.tasks` contracts and async property/explore runs — park hundreds of pending Tasks that each dispatch work onto GCD's global queue. Their aggregate lane demand exceeds what a constrained CI VM can schedule, and lanes that never get a thread trip the runner's idle timeout. The gate bounds the sum of in-flight lane reservations to ``limit`` regardless of how many test functions run at once: a run acquires its lanes, holds them for its whole duration, and releases on the way out. Excess runs suspend at the gate as parked continuations holding no thread, rather than piling onto GCD.
///
/// It is a budget, not a provider: GCD still hands out the actual threads. Admission is the whole effect. See `gcd-lane-admission-design.md` for the reservation accounting (async `.threads` reserves `N+1`, see ``LaneReservation``) and the call-site trace.
///
/// - Important: The gate is **async-only** and must never block a caller's thread. A blocking acquire was tried and removed: a synchronous `@Test` runs on the cooperative pool, so a blocking acquire parked cooperative-pool threads, which starved the pool that admitted runs need to service their `blockingAwait` continuations — deadlocking the whole suite. The sync `.threads` entry is therefore left ungated; it is self-limiting, since it blocks its own cooperative thread while running, so Swift Testing cannot start more than pool-width of them at once.
///
/// - Note: This is a `final class` guarded by an `NSLock` rather than an `actor` because ``release(_:)`` is called from synchronous contexts (inside the `dispatchToGCD` GCD closure, a `() -> Result`), which an actor's async-only surface cannot serve.
final class LaneGate: @unchecked Sendable {
    /// The default lane budget. Kept well under the 64-thread per-queue GCD wall, with headroom for the ungated sync `.threads` lanes and any uncounted usage.
    static let defaultLimit = 8

    /// The smallest budget that can satisfy every reservation: the largest single request is async `.threads` at `ConcurrencyLevel.max (4) + 1`.
    static let reservationFloor = 5

    /// Environment override for ``limit``, read once at init. Mirrors NIO's `NIO_SINGLETON_BLOCKING_POOL_THREAD_COUNT` convention.
    static let environmentOverrideKey = "EXHAUST_LANE_LIMIT"

    /// The process-global gate every gated concurrent runner acquires from.
    static let shared = LaneGate()

    /// The maximum number of lanes handed out at once. Immutable after init.
    let limit: Int

    private let lock = NSLock()

    /// Lanes currently available. Guarded by `lock`.
    private var free: Int

    /// Waiters in arrival order with the OLDEST at the tail, so `release` admits with `removeLast()` (O(1), FIFO) and enqueue is `insert(at: 0)` (O(n), off the admission loop, tiny n). Guarded by `lock`.
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

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

    /// Suspends until `count` lanes are available, then reserves them. The run parks as a continuation holding no thread rather than blocking a GCD worker.
    ///
    /// Cancellation is not handled: a unit test is never cancelled, and the async entries reach the gate through a non-cancellable `dispatchToGCD` hop, so a parked continuation is always eventually resumed on admission.
    func acquire(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            // Enqueue-under-the-lock closes the lost-wakeup race: the check and the enqueue are atomic against a concurrent `release`.
            if waiters.isEmpty, free >= count {
                free -= count
                lock.unlock()
                continuation.resume()
            } else {
                waiters.insert((count: count, continuation: continuation), at: 0)
                lock.unlock()
            }
        }
    }

    /// Returns `count` lanes to the budget and admits as many waiting runs as now fit, in FIFO order.
    ///
    /// Admission stops at the first waiter that does not fit, so a large request holds the line against later small ones. Continuations are resumed outside the lock, since a resume can run arbitrary code.
    func release(_ count: Int) {
        var resumptions: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        free += count
        while let head = waiters.last, free >= head.count {
            waiters.removeLast()
            free -= head.count
            resumptions.append(head.continuation)
        }
        lock.unlock()
        for continuation in resumptions {
            continuation.resume()
        }
    }
}

// MARK: - Test Introspection

extension LaneGate {
    /// Lanes currently available. For tests asserting the atomic-`N` accounting.
    var freeCount: Int {
        lock.withLocking { free }
    }

    /// Number of runs waiting for admission. For tests that must observe a waiter has parked before proceeding.
    var waiterCount: Int {
        lock.withLocking { waiters.count }
    }
}

// MARK: - Reservation Sizes

/// The lane count each gated concurrent entry reserves from the ``LaneGate``.
///
/// Centralized so the `+1` on the async `.threads` path lives in one commented place rather than as a magic number at each dispatch site. The sync `.threads` entry is not listed: it is ungated (see ``LaneGate``).
enum LaneReservation {
    /// The `.threads` reservation (sync and async): one lane per concurrency level, plus one for the coordinator GCD worker parked on `group.wait` while the level lanes run.
    static func threads(_ level: Int) -> Int {
        level + 1
    }

    /// The reservation for a run with no lane fan-out: cooperative `.tasks`, the sequential-async contract, and async `#exhaust`/`#explore`, which occupy a single coordinator worker.
    static let single = 1
}
