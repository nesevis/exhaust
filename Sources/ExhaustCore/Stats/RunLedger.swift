/// Records `(phase, outcome)` property-invocation events at the invocation site.
///
/// Each mode's runner records into a ledger instead of maintaining per-mode counter structs. Concurrent paths get per-lane ledgers that merge at the boundary. Report types become projections: `ExhaustReport` and `ExploreReport` read their invocation counts from the ledger rather than receiving them as separately threaded integers.
///
/// Outcomes are recorded honestly where the loop observes them. One runner cannot: the state machine runner counts reduction probes through a shared invocation counter that hides per-probe verdicts, so it records them through the aggregate overload with no skip or failure breakdown and only the phase totals are meaningful there.
package struct RunLedger: Sendable, Equatable {
    package enum Phase: Int, CaseIterable, Sendable {
        case screening = 0
        case sampling
        case warmup
        case regression
        case directedSampling
        case reduction
    }

    package enum Outcome: Int, CaseIterable, Sendable {
        case pass = 0
        case fail
        case skip
    }

    private static let phaseCount = Phase.allCases.count
    private static let outcomeCount = Outcome.allCases.count
    private static let countsSize = phaseCount * outcomeCount

    private var counts: [Int]

    package init() {
        counts = [Int](repeating: 0, count: Self.countsSize)
    }

    // MARK: - Recording

    package mutating func record(_ phase: Phase, _ outcome: Outcome, count: Int = 1) {
        counts[phase.rawValue * Self.outcomeCount + outcome.rawValue] += count
    }

    /// Records one phase's aggregate outcomes from an invocation total, a skip count, and a failure count.
    ///
    /// Phase loops that measure skips as a counter delta call this once per phase instead of recording per iteration. The pass count is derived, so the three outcome buckets always sum to `invocations`.
    package mutating func record(_ phase: Phase, invocations: Int, skips: Int = 0, failures: Int = 0) {
        assert(
            invocations >= skips + failures,
            "RunLedger accounting: \(invocations) invocations cannot contain \(skips) skips and \(failures) failures"
        )
        record(phase, .pass, count: invocations - skips - failures)
        record(phase, .skip, count: skips)
        record(phase, .fail, count: failures)
    }

    // MARK: - Merging

    package mutating func merge(_ other: RunLedger) {
        for index in 0 ..< Self.countsSize {
            counts[index] += other.counts[index]
        }
    }

    // MARK: - Queries

    package func count(_ phase: Phase, _ outcome: Outcome) -> Int {
        counts[phase.rawValue * Self.outcomeCount + outcome.rawValue]
    }

    package func count(_ phase: Phase) -> Int {
        let base = phase.rawValue * Self.outcomeCount
        var total = 0
        for offset in 0 ..< Self.outcomeCount {
            total += counts[base + offset]
        }
        return total
    }

    package var totalInvocations: Int {
        var total = 0
        for phase in Phase.allCases {
            total += count(phase)
        }
        return total
    }

    package var totalSkips: Int {
        var total = 0
        for phase in Phase.allCases {
            total += count(phase, .skip)
        }
        return total
    }
}
