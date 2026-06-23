import Exhaust
import Foundation
import Testing

/// Async variant of the Lowe hash map linearizability test. Exercises the async preemptive runner's linearizability checking, which requires per-lane response recording and the async `checkAsync` path on ``LinearizabilityChecker``.
@Suite("Preemptive linearizability: async Lowe hash map", .serialized, .tags(.contract))
struct PreemptiveAsyncLoweHashMapTests {
    @Test("Async runner detects ghost entry from buggy delete")
    func asyncDetectsGhostEntryFromBuggyDelete() async {
        let result = await #execute(
            AsyncLoweHashMapSpec.self,
            .concurrent(.two),
            .replay(.numeric(1337)),
            // Very high budget due to the non-deterministic interleaving.
            // Most failures are found after ~1100 iterations
            .budget(.custom(coverage: 10000, sampling: 500_000)),
            .suppress(.issueReporting)
        )
        #expect(result?.replaySeed != nil)
        #expect(result?.commands.count ?? 0 >= 2, "Need at least 2 concurrent commands to trigger a race")
    }
}

// MARK: - Spec

@Contract(.threads)
final class AsyncLoweHashMapSpec {
    @SystemUnderTest
    var map: BuggyHashMap = .init(capacity: 4)

    @Oracle
    func stateMatches(other: BuggyHashMap) -> Bool {
        map.snapshot == other.snapshot
    }

    @Command(weight: 3, BuggyHashMap.keyGen, .int(in: 0 ... 9))
    func update(key: Int, value: Int) async {
        map.update(key: key, value: value)
    }

    @Command(weight: 2, BuggyHashMap.keyGen)
    func delete(key: Int) async {
        map.delete(key: key)
    }

    @Command(weight: 1, BuggyHashMap.keyGen)
    func getOrElse(key: Int) async -> Int {
        map.getOrElse(key: key, default: -1)
    }

    func failureDescription() -> String? {
        "map: \(map.snapshot)"
    }
}
