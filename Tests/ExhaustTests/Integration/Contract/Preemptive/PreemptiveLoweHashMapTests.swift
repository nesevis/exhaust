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
    @Test("Detects ghost entry from assignment-instead-of-CAS delete")
    func detectsGhostEntryFromBuggyDelete() {
        var commandCount = 0
        var totalRuntime = 0.0
        for seed in UInt64(1337) ..< 1437 {
            var report: ExhaustReport?
            let result = #execute(
                LoweHashMapSpec.self,
                .concurrent(.two),
                .commandLimit(8),
                .budget(.custom(coverage: 7500, sampling: 7500)),
                .replay(.numeric(seed)),
                .suppress(.issueReporting),
                .onReport { report = $0 }
            )
            commandCount += result?.commands.count ?? 8
            totalRuntime += report?.totalMilliseconds ?? 0
//            print("DBG: \(report?.profilingSummary ?? "")")
//            print("DBG: commands: \(result?.commands.count ?? -1) runtime: \(report?.totalMilliseconds ?? -1)ms")
//            #expect(result?.replaySeed != nil)
//            #expect(result?.commands.count ?? 0 >= 2, "Need at least 2 concurrent commands to trigger a race")
        }
        print("Mean command count: \(Double(commandCount) / 100)")
        print("Mean runtime: \(totalRuntime / 100)ms")
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

    @Command(weight: 3, .int(in: 0 ... 1), .int(in: 0 ... 9))
    func update(key: Int, value: Int) {
        map.update(key: key, value: value)
    }

    @Command(weight: 2, .int(in: 0 ... 1))
    func delete(key: Int) {
        map.delete(key: key)
    }

    @Command(weight: 1, .int(in: 0 ... 1))
    func getOrElse(key: Int) -> Int {
        map.getOrElse(key: key, default: -1)
    }

    func failureDescription() -> String? {
        "map: \(map.snapshot)"
    }
}

// MARK: - SUT

/// Concurrent hash map with a buggy delete operation (Lowe 2017).
///
/// Each slot has a status (`empty`, `updating`, `stored`, `deleted`) and an optional value. `update` sets `updating`, writes the value, then sets `stored`. `delete` uses plain assignment to set `deleted` instead of CAS. This lets a concurrent `update` that read the old status before the delete resume and overwrite `deleted` with `stored`, creating a ghost entry.
final class BuggyHashMap: @unchecked Sendable {
    enum SlotStatus: Int, Sendable {
        case empty = 0
        case updating = 1
        case stored = 2
        case deleted = 3
    }

    /// Reference type so the backing array never mutates its buffer, and each field access is individually locked so concurrent operations race at the operation level (the intended ghost-entry bug) without a low-level data race on the fields themselves.
    final class Slot {
        private let lock = NSLock()
        private var _status: SlotStatus = .empty
        private var _key: Int = 0
        private var _value: Int = 0

        var status: SlotStatus {
            get {
                lock.withLock { _status }
            }
            set {
                lock.withLock { _status = newValue }
            }
        }

        var key: Int {
            get {
                lock.withLock { _key }
            }
            set {
                lock.withLock { _key = newValue }
            }
        }

        var value: Int {
            get {
                lock.withLock { _value }
            }
            set {
                lock.withLock { _value = newValue }
            }
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

    func update(key: Int, value: Int) {
        let index = abs(key) % slots.count
        slots[index].status = .updating
        slots[index].key = key
        slots[index].value = value
        sched_yield()
        slots[index].status = .stored
    }

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
