import Benchmark
import Exhaust
import Foundation

func registerPreemptiveLoweHashMapBenchmarks() {
    let seedCount = 50
    let baseSeed: UInt64 = 1337

    benchmark("Preemptive: Lowe hash map reduction quality") {
        var commandCount = 0
        var totalRuntime = 0.0
        var failureCount = 0

        for index in 0 ..< seedCount {
            let seed = baseSeed &+ UInt64(index)
            nonisolated(unsafe) var report: ExhaustReport?
            // `#execute` is async now; bridge it to this synchronous benchmark closure.
            let result = __ExhaustRuntime.blockingAwait {
                await #execute(
                    LoweHashMapBenchSpec.self,
                    .concurrent(.two),
                    .replay(.numeric(seed)),
                    .budget(.custom(coverage: 10000, sampling: 150_000)),
                    .suppress(.issueReporting),
                    .onReport { report = $0 }
                )
            }
            if let result {
                failureCount += 1
                commandCount += result.commands.count
            }
            totalRuntime += report?.totalMilliseconds ?? 0
        }

        let meanCommands = failureCount > 0 ? Double(commandCount) / Double(failureCount) : 0
        let meanRuntime = totalRuntime / Double(seedCount)
        print("Seeds: \(seedCount), failures: \(failureCount)")
        print("Mean command count: \(meanCommands)")
        print("Mean runtime: \(meanRuntime)ms")
    }
}

// MARK: - Spec

@Contract(.threads)
final class LoweHashMapBenchSpec {
    @SystemUnderTest
    var map: BuggyHashMapBench = .init(capacity: 4)

    static let keyGen = #gen(.int(in: 0 ... 31))

    @Oracle
    func stateMatches(other: BuggyHashMapBench) -> Bool {
        map.snapshot == other.snapshot
    }

    @Command(weight: 3, keyGen, .int(in: 0 ... 9))
    func update(key: Int, value: Int) {
        map.update(key: key, value: value)
    }

    @Command(weight: 2, keyGen)
    func delete(key: Int) {
        map.delete(key: key)
    }

    @Command(weight: 1, keyGen)
    func getOrElse(key: Int) -> Int {
        map.getOrElse(key: key, default: -1)
    }

    func failureDescription() -> String? {
        "map: \(map.snapshot)"
    }
}

// MARK: - SUT

/// Concurrent hash map with a buggy delete operation (Lowe 2017, Section 8).
///
/// Faithful to the paper's description: `update` spins while status is `.updating`, then uses compare-and-swap (CAS) to atomically transition to `.updating`, writes the value, and sets `.stored`. The CAS in `update` is correct. The bug is in `delete`, which uses plain assignment to set `.deleted` instead of CAS.
final class BuggyHashMapBench: @unchecked Sendable {
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

    @_optimize(none)
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

    @_optimize(none)
    func delete(key: Int) {
        let index = abs(key) % slots.count
        guard slots[index].key == key else { return }
        slots[index].status = .deleted
    }

    @_optimize(none)
    func getOrElse(key: Int, default defaultValue: Int) -> Int {
        let index = abs(key) % slots.count
        if slots[index].status == .stored, slots[index].key == key {
            return slots[index].value
        }
        return defaultValue
    }
}
