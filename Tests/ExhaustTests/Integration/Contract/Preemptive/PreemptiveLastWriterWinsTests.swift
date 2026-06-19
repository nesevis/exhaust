import Exhaust
import Foundation
import Testing

@Suite("Preemptive linearizability: false positive elimination", .serialized, .tags(.contract))
struct PreemptiveLastWriterWinsTests {
    @Test("Correctly synchronized last-writer-wins does not produce false positives")
    func correctlyImplementedLastWriterWinsPassesLinearizability() {
        let result = #execute(
            AtomicLastWriterWinsSpec.self,
            .concurrent(.two),
            .commandLimit(4),
            .idleTimeoutMs(5000),
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

// MARK: - SUT

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
