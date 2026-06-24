import Exhaust
import Foundation
import Testing

/// Reproduces the bug from Lowe, "Testing for Linearizability" (2017).
///
/// A concurrent hash map uses assignment instead of CAS to set slot status to `deleted`. This produces two manifestations of the same underlying bug:
///
/// **State-level ghost (2+ commands total).** `update(key, value)` is in progress (status is `.updating`) when `delete(key)` blindly writes `.deleted`. The update resumes and writes `.stored`, resurrecting the deleted key. The final state has a key that no valid sequential ordering produces. Caught by the oracle's state comparison alone.
///
/// **Response-level ghost (5+ commands total).** Same race, but the ghost is observed through `getOrElse(key)` returning a value for a key that should have been deleted. The final state may coincidentally match some valid ordering (putting the update last), but no ordering produces the observed `getOrElse` return value. The additional commands are prefix setup (populating the slot before the race) and the observing `getOrElse`. Caught by response comparison.
///
/// Lowe's paper describes the five-operation response-level variant. Our checker catches both because it checks responses and final state via the oracle across all valid orderings.
@Suite("Preemptive linearizability: Lowe hash map five-operation race", .serialized, .tags(.contract))
struct PreemptiveLoweHashMapTests {
    @Test("Detects ghost entry from assignment-instead-of-CAS delete (benchmark)", .disabled("Benchmark"))
    func detectsGhostEntryFromBuggyDelete() {
        var commandCount = 0
        var iterations: Double = 0
        var totalRuntime = 0.0
        for seed in UInt64(1337) ..< 1338 {
            var report: ExhaustReport?
            let result = #execute(
                LoweHashMapSpec.self,
                .concurrent(.two),
                .replay(.numeric(seed)),
//                .log(.debug),
                .budget(.custom(coverage: 10000, sampling: 150_000)),
//                .suppress(.issueReporting),
                .onReport { report = $0 }
            )
            iterations += 1
            commandCount += result?.commands.count ?? 20
            totalRuntime += report?.totalMilliseconds ?? 0
        }
        print("Mean command count: \(Double(commandCount) / iterations)")
        print("Mean runtime: \(totalRuntime / iterations)ms")
    }

    @Test("Detects ghost entry from assignment-instead-of-CAS delete")
    func detectsGhostEntryFromBuggyDeleteWithSeed() {
        #execute(
            LoweHashMapSpec.self,
            .concurrent(.two)
        )
    }
}

// MARK: - Spec

@Contract(.threads)
final class LoweHashMapSpec {
    @SystemUnderTest
    var map: BuggyHashMap = .init(capacity: 4)

    @Oracle
    func stateMatches(other: BuggyHashMap) -> Bool {
        map.snapshot == other.snapshot
    }

    @Command(weight: 3, BuggyHashMap.keyGen, .int(in: 0 ... 9))
    func update(key: Int, value: Int) {
        map.update(key: key, value: value)
    }

    @Command(weight: 2, BuggyHashMap.keyGen)
    func delete(key: Int) {
        map.delete(key: key)
    }

    @Command(weight: 1, BuggyHashMap.keyGen)
    func getOrElse(key: Int) -> Int {
        map.getOrElse(key: key, default: -1)
    }

    func failureDescription() -> String? {
        "map: \(map.snapshot.sorted(by: { $0.key < $1.key }))"
    }
}

// MARK: - SUT

/// Concurrent hash map with a buggy delete operation (Lowe 2017, Section 8).
///
/// Faithful to the paper's description: `update` spins while status is `.updating`, then uses compare-and-swap (CAS) to atomically transition to `.updating`, writes the value, and sets `.stored`. The CAS in `update` is correct. The bug is in `delete`, which uses plain assignment to set `.deleted` instead of CAS. When an `update` is in progress (status is `.updating`), a correct delete would CAS-fail. The buggy delete writes `.deleted` unconditionally, and the in-progress update's final `.stored` write overwrites it, resurrecting the entry.
///
/// Each field access is individually locked (NSLock) so concurrent operations race at the operation level (the intended ghost-entry bug) without a low-level data race on the fields themselves.
final class BuggyHashMap: @unchecked Sendable {
    static let keyGen = #gen(.int(in: 0 ... 31))

    enum SlotStatus: Int, Sendable {
        case empty = 0
        case updating = 1
        case stored = 2
        case deleted = 3
    }

    final class Slot {
        private let lock = NSLock()
        private var _status: SlotStatus = .empty
        private var _key: Int = 0
        private var _value: Int = 0

        var status: SlotStatus {
            get { lock.withLock { _status } }
            set { lock.withLock { _status = newValue } }
        }

        /// Atomically sets status to `desired` if it currently equals `expected`. Returns whether the swap occurred.
        func compareAndSwapStatus(expected: SlotStatus, desired: SlotStatus) -> Bool {
            lock.withLock {
                guard _status == expected else { return false }
                _status = desired
                return true
            }
        }

        var key: Int {
            get { lock.withLock { _key } }
            set { lock.withLock { _key = newValue } }
        }

        var value: Int {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    private let slots: [Slot]

    init(capacity: Int) {
        slots = (0 ..< capacity).map { _ in Slot() }
    }

    var snapshot: [Int: Int] {
        var result: [Int: Int] = [:]
        for slot in slots where slot.status == .stored {
            result[slot.key] = slot.value
        }
        return result
    }

    /// Spins while status is `.updating`, then CAS to `.updating`, writes key/value, sets `.stored`.
    func update(key: Int, value: Int) {
        let index = abs(key) % slots.count
        let slot = slots[index]
        while true {
            let current = slot.status
            if current == .updating { continue }
            if slot.compareAndSwapStatus(expected: current, desired: .updating) { break }
        }
        slot.key = key
        slot.value = value
        slot.status = .stored
    }

    /// BUG: uses plain assignment instead of CAS. A concurrent `update` that already holds `.updating` will overwrite this `.deleted` with `.stored` when it finishes.
    func delete(key: Int) {
        let index = abs(key) % slots.count
        guard slots[index].key == key else { return }
        slots[index].status = .deleted
    }

    func getOrElse(key: Int, default defaultValue: Int) -> Int {
        let index = abs(key) % slots.count
        if slots[index].status == .stored, slots[index].key == key {
            return slots[index].value
        }
        return defaultValue
    }
}
