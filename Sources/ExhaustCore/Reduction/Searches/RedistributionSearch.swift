//
//  RedistributionSearch.swift
//  Exhaust
//

// MARK: - Redistribution Search

/// Moves magnitude between type-compatible leaf pairs to enable future structural operations.
///
/// For each source-receiver pair, binary-searches on delta magnitude via ``BinarySearchStepper`` to find the largest accepted transfer. The graph determines which pairs; the search determines how much. Up to ``ReductionTuning/redistributionMaxPasses`` replay passes re-evaluate accepted pairs for further convergence.
///
/// The graph cannot predict which delta keeps the property failing (the delta lies above the opacity boundary), so only property feedback can find it.
///
/// Candidate construction, compact pair ranking, and rational-arithmetic helpers live in `RedistributionSearch+Probing.swift`, `RedistributionSearch+Ranking.swift`, and `RedistributionSearch+RationalMath.swift`.
struct RedistributionSearch: ReductionSearch {
    // MARK: - State

    var valueState = ValueEncoderState()
    var mode: Mode = .idle

    enum Mode {
        case idle
        case active(RedistributionState)
    }

    /// Scaled numerators over a common denominator, for a pair that mixes types or involves a float and so cannot move a bit-pattern delta directly.
    ///
    /// When either side is an integer, ``intStepSize`` equals the denominator, so the integer side moves in whole units. ``distanceInSteps`` is the source's distance to its target in those units.
    struct MixedRedistributionContext {
        let sourceNumerator: Int64
        let sinkNumerator: Int64
        let denominator: UInt64
        let intStepSize: UInt64
        let sourceMovesUpward: Bool
        let distanceInSteps: UInt64
    }

    /// The pair being searched, its delta binary search, and the replay passes over accepted pairs.
    struct RedistributionState {
        let pairs: [PreparedPair]
        var pairIndex: Int
        var stepper: BinarySearchStepper?
        /// Whether the last returned candidate came from the current pair, so the incoming feedback belongs to it.
        var didEmitCandidate: Bool
        /// Whether the current pair's full-delta probe, which moves the source all the way to its target, has been tried.
        var triedFullDelta: Bool
        /// Pairs that accepted during the current pass, replayed by the next one.
        var acceptedPairIndices: Set<Int>
        var passCount: Int
        /// The pairs a replay pass visits. Nil on the first pass, which visits every pair.
        var activePairIndices: Set<Int>?
    }

    /// Replay passes over accepted pairs before the search stops re-evaluating them.
    let maxPasses: Int

    /// Pairs the search keeps from the scope, best ranked first.
    let maxPairs: Int

    // MARK: - Search

    /// Ranks `scope`'s pairs against `sequence` and keeps the best ``ReductionTuning/redistributionMaxPairs`` of them.
    init(scope: RedistributionScope, sequence: ChoiceSequence, graph: ChoiceGraph, tuning: ReductionTuning) {
        maxPasses = tuning.redistributionMaxPasses
        maxPairs = tuning.redistributionMaxPairs
        valueState.reset(sequence: sequence)
        startRedistribution(scope: scope, graph: graph)
    }

    mutating func next(_ feedback: SearchFeedback, into buffer: inout ChoiceSequence) -> ReductionCandidate? {
        guard case var .active(state) = mode else {
            return nil
        }

        let lastAccepted = feedback.isAccepted
        if case let .accepted(recovered) = feedback {
            // Leaf positions were resolved against the dispatch-time sequence, so a recovered sequence of a different length ends the search.
            guard recovered.count == valueState.sequence.count else {
                return nil
            }
            valueState.sequence = recovered
            state.acceptedPairIndices.insert(state.pairIndex)
        }
        guard let built = nextRedistributionProbe(state: &state, lastAccepted: lastAccepted) else {
            mode = .active(state)
            return nil
        }
        buffer = built
        let mutation = valueState.buildLeafValuesMutation(candidate: buffer)
        mode = .active(state)
        return .eager(mutation: mutation, admission: .standard)
    }
}
