import Exhaust
import Foundation
import Testing

@Suite("Preemptive linearizability: false positive elimination", .serialized, .tags(.contract))
struct PreemptiveLinearizabilityTests {
    @Test("Correctly synchronized last-writer-wins does not produce false positives")
    func correctlyImplementedLastWriterWinsPassesLinearizability() {
        let result = #execute(
            AtomicLastWriterWinsSpec.self,
            .concurrent(.two),
            .commandLimit(4),
            .suppress(.issueReporting)
        )
        #expect(result == nil, "A correctly synchronized SUT should not produce failures. The fixed-ordering oracle would false-positive here; linearizability should accept both orderings.")
    }
}

// MARK: - Spec

/// Two concurrent `setValue` commands on the same key with different values.
///
/// The SUT is correctly synchronized (NSLock). Either ordering is valid, but the fixed-ordering oracle compares against array order, which may differ from the GCD execution order. Without linearizability confirmation, this produces a false positive roughly 50% of the time.
@Contract(.threads)
final class AtomicLastWriterWinsSpec {
    @SystemUnderTest
    var store: AtomicKeyValueStore = .init()

    @Oracle
    func stateMatches(other: AtomicKeyValueStore) -> Bool {
        store.snapshot == other.snapshot
    }

    @Command(weight: 1, .int(in: 0 ... 9))
    func setValue(value: Int) {
        store.set("key", to: value)
    }

    func failureDescription() -> String? {
        "store: \(store.snapshot)"
    }
}

// MARK: - Failing test

@Suite("Preemptive linearizability: real race detection", .serialized, .tags(.contract))
struct PreemptiveLinearizabilityRaceTests {
    @Test("Detects lost update in unsynchronized counter")
    func detectsLostUpdateInUnsynchronizedCounter() throws {
        var report: ExhaustReport?
        let result = try #require(
            #execute(
                RacyAccountSpec.self,
                .concurrent(.two),
                .commandLimit(6),
                .budget(.custom(coverage: 0, sampling: 400)),
                .suppress(.issueReporting),
                .onReport { report = $0 }
            )
        )
        print(report?.profilingSummary)
        #expect(result.replaySeed != nil)
        #expect(result.commands.count >= 2, "Need at least 2 concurrent commands to trigger the race")
    }
}

// MARK: - Racy spec

/// Account where deposits are atomic but withdrawals race.
///
/// The `withdraw` path does an unsynchronized read-modify-write, so two concurrent withdrawals can both read the same balance and each subtract from it, losing an update.
/// The `deposit` path is lock-protected, so a sequence of deposits must run before any withdrawal is valid. This forces the reducer to keep some prefix commands and gives the pipeline enough depth to exercise lane-collapse before the linearizability check.
@Contract(.threads)
final class RacyAccountSpec {
    @SystemUnderTest
    var account: RacyAccount = .init()

    @Oracle
    func balanceMatches(other: RacyAccount) -> Bool {
        account.balance == other.balance
    }

    @Command(weight: 3, .int(in: 1 ... 10))
    func deposit(amount: Int) {
        account.deposit(amount)
    }

    @Command(weight: 2, .int(in: 1 ... 5))
    func withdraw(amount: Int) throws {
        guard account.balance >= amount else { throw skip() }
        account.withdraw(amount)
    }

    func failureDescription() -> String? {
        "balance: \(account.balance)"
    }
}

// MARK: - Lowe hash map bug (five-operation race)

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
        var report: ExhaustReport?
        let result = #execute(
            LoweHashMapSpec.self,
            .concurrent(.two),
            .commandLimit(8),
            .budget(.extensive),
            .suppress(.issueReporting),
            .onReport { report = $0 }
        )
        #expect(result?.replaySeed != nil)
        #expect(result?.commands.count ?? 0 >= 2, "Need at least 2 concurrent commands to trigger a race")
    }
}

// MARK: - Contract

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

// MARK: - SUTs

/// Lock-synchronized key-value store. All operations are atomic.
final class AtomicKeyValueStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Int] = [:]

    var snapshot: [String: Int] {
        lock.withLock { storage }
    }

    func set(_ key: String, to value: Int) {
        lock.withLock { storage[key] = value }
    }
}

/// Concurrent hash map with a buggy delete operation (Lowe 2017).
///
/// Each slot has a status (`empty`, `updating`, `stored`, `deleted`) and an
/// optional value. `update` uses CAS to transition from a non-updating status
/// to `updating`, writes the value, then sets `stored`. `delete` uses plain
/// assignment to set `deleted` instead of CAS. This lets a concurrent `update`
/// that read the old status before the delete resume and overwrite `deleted`
/// with `stored`, creating a ghost entry.
///
/// The `Thread.sleep` in `update` widens the window between the status read
/// and the status write, making the preemption point reachable under GCD
/// scheduling.
final class BuggyHashMap: @unchecked Sendable {
    enum SlotStatus: Int, Sendable {
        case empty = 0
        case updating = 1
        case stored = 2
        case deleted = 3
    }

    /// Reference type so the backing array never mutates its buffer, and each field access is individually
    /// locked so concurrent operations race at the operation level (the intended ghost-entry bug) without a
    /// low-level data race on the fields themselves. A raw `var` would be UB under concurrent access and can
    /// corrupt unrelated slots; per-field locking keeps every read and write atomic while leaving `update`
    /// and `delete` free to interleave (neither holds a lock across its whole body), which is the actual race.
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
        // Widen the window before the final status write so a concurrent delete can set `.deleted` here and have it overwritten back to `.stored` below — the ghost-entry preemption point. The issue is still discoverable without it, but is much rarer.
        sched_yield()
        slots[index].status = .stored
    }

    // BUG: uses assignment instead of CAS.
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

/// Account with atomic deposits but racy withdrawals.
///
/// `deposit` is lock-protected. `withdraw` deliberately skips the lock,
/// so two concurrent withdrawals both read the same balance and each
/// subtract independently, losing one update.
final class RacyAccount: @unchecked Sendable {
    private let lock = NSLock()
    private var _balance: Int = 0

    var balance: Int {
        lock.withLock { _balance }
    }

    func deposit(_ amount: Int) {
        lock.withLock { _balance += amount }
    }

    func withdraw(_ amount: Int) {
        let current = _balance
        Thread.sleep(forTimeInterval: 0.0001)
        _balance = current - amount
    }
}
