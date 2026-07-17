/// Records `(phase, outcome)` events and non-overlapping elapsed intervals at the invocation site.
///
/// Each mode's runner records into a ledger instead of maintaining per-mode counter structs. Concurrent paths get per-lane ledgers that merge at the boundary. Report types become projections: `ExhaustReport`, `ExploreReport`, `FuzzReport`, and `StateMachineResult` read their invocation counts from the ledger rather than receiving them as separately threaded integers.
package struct RunLedger: Sendable, Equatable {
    package enum Phase: Int, CaseIterable, Sendable {
        case screening = 0
        case sampling
        case mutation
        case warmup
        case regression
        case directedSampling
        case reduction
        case normalization
        case classification
        case recovery
        case pruning
        case diagnostic
    }

    package enum Outcome: Int, CaseIterable, Sendable {
        case pass = 0
        case fail
        case skip
        case rejected
    }

    private static let phaseCount = Phase.allCases.count
    private static let outcomeCount = Outcome.allCases.count
    private static let countsSize = phaseCount * outcomeCount

    private var counts: [Int]
    private var elapsed: [UInt64]

    package init() {
        counts = [Int](repeating: 0, count: Self.countsSize)
        elapsed = [UInt64](repeating: 0, count: Self.phaseCount)
    }

    // MARK: - Recording

    package mutating func record(_ phase: Phase, _ outcome: Outcome) {
        counts[phase.rawValue * Self.outcomeCount + outcome.rawValue] += 1
    }

    package mutating func addElapsed(_ phase: Phase, nanoseconds: UInt64) {
        elapsed[phase.rawValue] += nanoseconds
    }

    // MARK: - Merging

    package mutating func merge(_ other: RunLedger) {
        for index in 0 ..< Self.countsSize {
            counts[index] += other.counts[index]
        }
        for index in 0 ..< Self.phaseCount {
            elapsed[index] += other.elapsed[index]
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

    package func invocations(_ phase: Phase) -> Int {
        count(phase, .pass) + count(phase, .fail) + count(phase, .skip)
    }

    package func elapsedNanoseconds(_ phase: Phase) -> UInt64 {
        elapsed[phase.rawValue]
    }

    package var totalInvocations: Int {
        var total = 0
        for phase in Phase.allCases {
            total += invocations(phase)
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
