import Foundation

/// A process-global budget over the GCD lanes Exhaust's concurrent runners occupy at once.
///
/// Under `swift test --parallel`, Exhaust's concurrent runs — preemptive `.threads` contracts (each fanning commands across N GCD lanes), cooperative `.tasks` contracts, and async property/explore runs — can all be in flight at once. On a constrained (single-core) CI runner, dozens of concurrent preemptive runs mean their lanes contend for the CPU and never start within the runner's idle window, so every probe times out and the suite crawls. The gate bounds the sum of in-flight lane reservations to ``limit``: a run acquires its lanes, holds them for its whole duration, and releases on the way out, so at most ~``limit``/(N+1) preemptive runs execute at once and their lanes are not starved. Excess runs suspend at the gate as parked continuations holding no thread, rather than piling onto GCD.
///
/// It is a budget, not a provider: GCD still hands out the actual threads. Admission is the whole effect. See `gcd-lane-admission-design.md` for the reservation accounting (`.threads` reserves `N+1`, see ``LaneReservation``) and the call-site trace.
///
/// - Important: The gate is **async-only**: it exposes a suspending ``acquire(_:)`` and never blocks a caller's thread. A blocking acquire was tried and removed — a synchronous `@Test` runs on the cooperative pool, so blocking it starved the pool that admitted runs need to service their `blockingAwait` continuations, deadlocking the suite. Sync `.threads` contracts reach the gate through the same non-blocking `acquire`: their `#execute` dispatch is `async` (`__runContractDispatch` is `async`), so the synchronous machine runs on a GCD worker via `dispatchToGCD` and acquires without ever blocking a cooperative thread.
///
/// - Note: This is a `final class` guarded by an `NSLock` rather than an `actor` because ``release(_:)`` is called from synchronous contexts (inside the `dispatchToGCD` GCD closure, a `() -> Result`), which an actor's async-only surface cannot serve. Marked `@unchecked Sendable` because the mutable state, `free` and `waiters`, is read and written from many threads (async acquirers, and releasers on GCD workers); every access is serialized under `lock`, so the state is never touched concurrently.
final class LaneGate: @unchecked Sendable {
    /// The default lane budget. Bounds concurrent preemptive runs to ~`limit`/(N+1) so their lanes are not starved on a constrained runner, while staying under the 64-thread per-queue GCD wall. Overridable via ``environmentOverrideKey``.
    static let defaultLimit = 32

    /// The smallest budget that can satisfy every reservation: the largest single request is a `.threads` run at the highest ``ConcurrencyLevel`` plus its coordinator lane. Derived rather than hardcoded so a new `ConcurrencyLevel` case raises the floor automatically.
    static let reservationFloor = LaneReservation.threads(ConcurrencyLevel.allCases.map(\.rawValue).max() ?? 1)

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
    /// Cancellation is not handled: a unit test is never canceled, and the async entries reach the gate through a non-cancelable `dispatchToGCD` hop, so a parked continuation is always eventually resumed on admission.
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
/// Centralized so the `+1` on the `.threads` path lives in one commented place rather than as a magic number at each dispatch site.
enum LaneReservation {
    /// The `.threads` reservation (sync and async): one lane per concurrency level, plus one for the coordinator GCD worker parked on `group.wait` while the level lanes run.
    static func threads(_ level: Int) -> Int {
        level + 1
    }

    /// The reservation for a run with no lane fan-out: cooperative `.tasks`, the sequential-async contract, and async `#exhaust`/`#explore`, which occupy a single coordinator worker.
    static let single = 1

    /// The reservation for an async property run: the coordinator worker, widened to the `.parallelize` lane count when the sampling phase fans out via `concurrentPerform` (the coordinator doubles as one of the lanes, so no `+1`).
    static func property(parallelLanes: Int) -> Int {
        max(single, parallelLanes)
    }
}
