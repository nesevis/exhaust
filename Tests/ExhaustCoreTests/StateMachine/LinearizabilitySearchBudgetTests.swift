import Testing
@testable import ExhaustCore

// The DFS is exponential and nothing outside it bounds one check: the reduction deadline bounds the reducer and the idle timeout bounds the concurrent execution, but an oracle-flagged probe searches until it finishes. These guard the replay budget that stops it, and the direction it resolves in when it stops early.
//
// The unsatisfiable oracle below stands in for both truncated outcomes deliberately: abandonment reports linearizable regardless of what a longer search would have found, so a real violation cut off by the budget is indistinguishable from these histories and needs no separate test.

@Suite("Linearizability search budget")
struct LinearizabilitySearchBudgetTests {
    @Test("A search too large for the replay budget stops instead of running to exhaustion")
    func oversizedSearchStopsWithinBudget() {
        // Three lanes of seven void commands is multinomial(21; 7, 7, 7) orderings, hundreds of millions of them, and the oracle below rejects every one. Without the budget this call does not return in any useful time.
        let measurement = measureVoidSearch(laneCount: 3, commandsPerLane: 7)

        #expect(measurement.replayCalls <= PreemptiveReduction.linearizabilitySearchReplayBudget)
    }

    @Test("An abandoned search reports linearizable rather than manufacturing a counterexample")
    func abandonedSearchResolvesAsLinearizable() {
        // The oracle is unsatisfiable, so an exhaustive search would report a violation. Stopping early means the search neither found an explanation nor ruled one out, and an inconclusive result must not surface as a counterexample.
        let measurement = measureVoidSearch(laneCount: 3, commandsPerLane: 7)

        #expect(measurement.replayCalls <= PreemptiveReduction.linearizabilitySearchReplayBudget)
        #expect(measurement.linearizable)
    }

    @Test("A search small enough to finish still reaches its verdict")
    func completableSearchIsNotAbandoned() {
        // multinomial(6; 3, 3) is 20 orderings, far inside the budget, so the unsatisfiable oracle must produce the honest verdict rather than the abandonment fallback.
        let measurement = measureVoidSearch(laneCount: 2, commandsPerLane: 3)

        #expect(measurement.replayCalls < PreemptiveReduction.linearizabilitySearchReplayBudget)
        #expect(measurement.linearizable == false)
    }

    @Test("A prefix replay is charged for the commands it runs")
    func prefixReplayConsumesBudget() {
        // A sibling retry rebuilds the sequential prefix on a fresh spec before re-placing the ordering. Charging only the concurrent commands would let a long prefix multiply the search's real cost by a factor the budget cannot see, so the same history with a longer prefix must exhaust the budget after fewer concurrent replays.
        let withoutPrefix = measureVoidSearch(laneCount: 3, commandsPerLane: 7, prefixLength: 0)
        let withPrefix = measureVoidSearch(laneCount: 3, commandsPerLane: 7, prefixLength: 100)

        #expect(withPrefix.replayCalls < withoutPrefix.replayCalls)
        // The direct evidence: each sibling retry costs the prefix's own length, so the budget affords far fewer prefix replays when the prefix is long.
        #expect(withPrefix.prefixCalls < withoutPrefix.prefixCalls)
    }
}

// MARK: - Helpers

private struct SearchMeasurement {
    let linearizable: Bool
    let replayCalls: Int
    let prefixCalls: Int
}

/// Builds a history of `laneCount` lanes of `commandsPerLane` void commands with no timing intervals, so no real-time edge prunes anything, gives it an oracle no ordering can satisfy, and counts the replay closures the DFS invokes.
///
/// `prefixLength` is reported to the checker but not replayed: the closures only need to cost the search what a prefix of that size would, and running the commands would measure the harness rather than the budget.
private func measureVoidSearch(
    laneCount: Int,
    commandsPerLane: Int,
    prefixLength: Int = 0
) -> SearchMeasurement {
    var lanes: [[ProbeObservation]] = []
    var nextValue = 0
    for laneIndex in 0 ..< laneCount {
        var lane: [ProbeObservation] = []
        for _ in 0 ..< commandsPerLane {
            lane.append(
                ProbeObservation(
                    lane: UInt8(laneIndex + 1),
                    command: ProbeCommand(value: nextValue),
                    outcome: .returnedVoid
                )
            )
            nextValue += 1
        }
        lanes.append(lane)
    }

    let checker = LinearizabilityChecker(laneResponses: lanes)
    var replayCalls = 0
    var prefixCalls = 0
    var model: [Int] = []
    // One element longer than the history, so no ordering of these commands can produce it.
    let unreachableFinalState = Array(0 ... (laneCount * commandsPerLane))

    let result = checker.check(
        prefixLength: prefixLength,
        replayPrefix: {
            prefixCalls += 1
            model = []
            return true
        },
        replayCommand: { laneIndex, commandIndex in
            replayCalls += 1
            model.append(lanes[laneIndex][commandIndex].command.value)
            return .init(returnValue: nil, isSkipped: false)
        },
        checkOracle: {
            model == unreachableFinalState
        },
        failureDescription: { nil }
    )

    let linearizable = switch result {
        case .linearizable: true
        case .notLinearizable: false
    }
    return SearchMeasurement(
        linearizable: linearizable,
        replayCalls: replayCalls,
        prefixCalls: prefixCalls
    )
}

private struct ProbeCommand: CustomStringConvertible {
    let value: Int

    var description: String {
        "append(\(value))"
    }
}

private typealias ProbeObservation = ObservedResponse<ProbeCommand>
