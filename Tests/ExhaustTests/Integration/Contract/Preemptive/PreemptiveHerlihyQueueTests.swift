import Exhaust
import Foundation
import Testing

/// Reproduces a linearizability violation in a lock-free FIFO queue based on Herlihy & Wing (1990), Section 4.
///
/// The correct implementation uses fetch-and-add (INC) to atomically reserve an array slot during enqueue, and atomic swap (SWAP) to claim an item during dequeue. Both operations are lock-free: no thread blocks waiting for another.
///
/// **Bug**: `enqueue` replaces the atomic fetch-and-add with a non-atomic read-then-write on the `back` index. Two concurrent enqueues read the same index, both write to the same slot, and the second store overwrites the first — a lost enqueue. The queue permanently loses an item, violating linearizability: no sequential ordering of the operations can produce a queue missing an enqueued value.
///
/// **Detection**: The oracle compares remaining items after all operations complete. A lost enqueue means the concurrent SUT is missing an item that every valid sequential ordering would include. Response-level detection also works: `dequeue` returns nil or a different item than any valid ordering predicts.
@Suite("Preemptive linearizability: Herlihy-Wing lock-free queue lost enqueue", .serialized, .tags(.contract))
struct PreemptiveHerlihyQueueTests {
    @Test("Detects lost enqueue from non-atomic back increment", .disabled("Benchmark"))
    func detectsLostEnqueue() async {
        var commandCount = 0
        var iterations: Double = 0
        var totalRuntime = 0.0
        for seed in UInt64(1) ... 200 {
            var report: ExhaustReport?
            let result = await #execute(
                HerlihyQueueSpec.self,
                .concurrent(.two),
                .budget(.custom(coverage: 0, sampling: 500_000)),
//                .log(.debug),
                .replay(.numeric(seed)),
                .onReport { report = $0 },
                .suppress(.all)
            )
            iterations += 1
            commandCount += result?.commands.count ?? 20
            totalRuntime += report?.totalMilliseconds ?? 0
            print("Reduction summary: \(report?.profilingSummary ?? "")")
        }
        print("Mean command count: \(Double(commandCount) / iterations)")
        print("Mean runtime: \(totalRuntime / iterations)ms")
//        #expect(result != nil, "Should detect the lost-enqueue bug")
    }
}

// MARK: - Spec

@Contract(.threads)
final class HerlihyQueueSpec {
    @SystemUnderTest
    var queue: BuggyHerlihyQueue = .init(capacity: 32)

    @Oracle
    func contentsMatch(other: BuggyHerlihyQueue) -> Bool {
        queue.snapshot == other.snapshot
    }

    @Command(weight: 3, .int(in: 0 ... 99))
    func enqueue(value: Int) {
        queue.enqueue(value)
    }

    @Command(weight: 2)
    func dequeue() -> Int? {
        queue.dequeue()
    }

    func failureDescription() -> String? {
        "queue: \(queue.snapshot)"
    }
}

// MARK: - SUT

/// Lock-free FIFO queue from Herlihy & Wing (1990), Section 4.
///
/// Faithful to the paper's structure: an array of nullable slots with a `back` index pointing to the next free position. `enqueue` reserves a slot by incrementing `back`, then stores the item. `dequeue` scans from index 0 to `back - 1`, atomically swapping each slot with nil; the first non-nil value found is returned. No mutual exclusion: the only synchronization is atomic operations on individual slots.
///
/// **Bug**: `enqueue` uses a non-atomic read-then-write on `back` instead of fetch-and-add. Two concurrent enqueues read the same `back` value, both increment to the same next index, and the second store silently overwrites the first. The lost item never appears in any subsequent dequeue.
///
/// Each field access is individually locked (NSLock) so operations race at the logical level (the intended lost-enqueue bug) without a low-level data race on the fields themselves.
final class BuggyHerlihyQueue: @unchecked Sendable, CustomDebugStringConvertible {
    final class Slot {
        private let lock = NSLock()
        private var _value: Int?

        func load() -> Int? {
            lock.withLock { _value }
        }

        func store(_ value: Int) {
            lock.withLock { _value = value }
        }

        func swap(_ newValue: Int?) -> Int? {
            lock.withLock {
                let old = _value
                _value = newValue
                return old
            }
        }
    }

    private let backLock = NSLock()
    private var _back: Int = 0
    let capacity: Int
    private let slots: [Slot]

    init(capacity: Int) {
        self.capacity = capacity
        slots = (0 ..< capacity).map { _ in Slot() }
    }

    var debugDescription: String {
        "BuggyHerlihyQueue(\(snapshot))"
    }

    /// Items currently in the queue, in slot order. Excludes nil (dequeued or not-yet-stored) slots.
    var snapshot: [Int] {
        let range = backLock.withLock { _back }
        return (0 ..< range).compactMap { slots[$0].load() }
    }

    /// BUG: non-atomic read-then-write of `back`. Two concurrent enqueues read the same index, and the second store overwrites the first.
    @_optimize(none)
    func enqueue(_ value: Int) {
        let index = backLock.withLock { _back }
        guard index < capacity else { return }
        backLock.withLock { _back = index + 1 }
        slots[index].store(value)
    }

    /// Scans from index 0 to `back - 1`, atomically swapping each slot with nil. Returns the first non-nil value found. Retries up to five times to handle items whose store is in flight (INC completed but STORE not yet visible).
    @_optimize(none)
    func dequeue() -> Int? {
        for _ in 0 ..< 5 {
            let range = backLock.withLock { _back }
            guard range > 0 else { return nil }
            for index in 0 ..< range {
                if let value = slots[index].swap(nil) {
                    return value
                }
            }
        }
        return nil
    }
}
