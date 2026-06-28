import Exhaust
import Foundation
import Testing

@Suite("Preemptive linearizability: response-only ghost behind a blind oracle", .serialized, .tags(.contract))
struct PreemptiveResponseOnlyGhostTests {
    /// `RacySet.add(x)` carries a response-only race: two concurrent `add(x)` can both return `true`, which no sequential ordering permits, while the final state is the same single element under every interleaving.
    /// A final-state oracle cannot witness the violation, so detection has to come from comparing the per-command responses against a sequential replay.
    @Test("Response-only violation is detected by the realized-order witness (C1 regression)")
    func responseOnlyViolationShouldBeDetected() {
        let result = #execute(
            RacySetSpec.self,
            .concurrent(.two),
            .suppress(.all)
        )
        #expect(result?.status == .fail)
    }
}

@Contract(.threads)
final class RacySetSpec {
    @SystemUnderTest
    var system = RacySet()

    /// Final-state only, and set union is interleaving-independent, so this oracle passes for every interleaving and can never witness the race. That is deliberate.
    @Oracle
    func contentsMatch(other: RacySet) -> Bool {
        system.snapshot == other.snapshot
    }

    @Command(weight: 1, RacySet.elementGen)
    func add(element: Int) -> Bool {
        system.add(element)
    }

    func failureDescription() -> String? {
        "set: \(system.snapshot.sorted())"
    }
}

/// A set whose `add` reports whether the element was newly inserted.
///
/// Each field is individually locked, so there is no low-level data race; the bug is at the operation level.
/// The "was it absent?" decision is read under the lock, but the window between deciding and inserting lets two concurrent `add(x)` calls both observe `x` absent and both return `true`.
/// Run sequentially, the second `add(x)` returns `false`.
final class RacySet: @unchecked Sendable {
    /// Small domain so two lanes frequently add the same element.
    static let elementGen = #gen(.int(in: 0 ... 1))

    private let lock = NSLock()
    private var storage: Set<Int> = []

    func add(_ element: Int) -> Bool {
        let wasAbsent = lock.withLock { storage.contains(element) == false }
        Thread.sleep(forTimeInterval: 0.0001) // Widen the decide-to-insert window so two lanes reliably overlap.
        _ = lock.withLock { storage.insert(element) }
        return wasAbsent
    }

    var snapshot: Set<Int> {
        lock.withLock { storage }
    }
}
