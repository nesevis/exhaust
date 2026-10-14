//
//  ScopedRedistributionSearch.swift
//  Exhaust
//

// MARK: - Redistribution Search

/// Moves magnitude between type-compatible leaf pairs to enable future structural operations.
///
/// For each source-receiver pair, binary-searches on delta magnitude via ``BinarySearchStepper`` to find the largest accepted transfer. The graph determines which pairs; the search determines how much. Up to ``ScopedReductionTuning/redistributionMaxPasses`` replay passes re-evaluate accepted pairs for further convergence.
///
/// The delta magnitude is above the opacity boundary and requires predicate feedback to find.
///
/// Candidate construction, compact pair ranking, and rational-arithmetic helpers live in `ScopedRedistributionSearch+Probing.swift`, `ScopedRedistributionSearch+Ranking.swift`, and `ScopedRedistributionSearch+RationalMath.swift`.
struct ScopedRedistributionSearch: ScopedSearch {
    // MARK: - State

    var valueState = ValueEncoderState()
    var mode: Mode = .idle

    enum Mode {
        case idle
        case active(RedistributionState)
    }

    /// Holds the rational-arithmetic context for a single redistribution pair, including the LCM denominator and scaled numerators needed to redistribute value between heterogeneous-type nodes.
    struct MixedRedistributionContext {
        let sourceNumerator: Int64
        let sinkNumerator: Int64
        let denominator: UInt64
        let intStepSize: UInt64
        let sourceMovesUpward: Bool
        let distanceInSteps: UInt64
    }

    /// Tracks the binary search state for redistribution magnitude and the current pair iteration across probes.
    struct RedistributionState {
        let pairs: [PreparedPair]
        var pairIndex: Int
        var stepper: BinarySearchStepper?
        var didEmitCandidate: Bool
        var lastEmittedCandidate: ChoiceSequence?
        var triedFullDelta: Bool
        var acceptedPairIndices: Set<Int>
        var passCount: Int
        var activePairIndices: Set<Int>?
    }

    /// Replay passes over accepted pairs before the search stops re-evaluating them.
    let maxPasses: Int

    /// Pairs the search keeps from the scope, best ranked first.
    let maxPairs: Int

    // MARK: - Search

    /// Ranks `scope`'s pairs against `sequence` and keeps the best ``ScopedReductionTuning/redistributionMaxPairs`` of them.
    init(scope: RedistributionScope, sequence: ChoiceSequence, graph: ChoiceGraph, tuning: ScopedReductionTuning) {
        maxPasses = tuning.redistributionMaxPasses
        maxPairs = tuning.redistributionMaxPairs
        valueState.reset(sequence: sequence)
        startRedistribution(scope: scope, graph: graph)
    }

    mutating func next(_ feedback: ScopedSearchFeedback, into buffer: inout ChoiceSequence) -> ScopedCandidate? {
        guard case var .active(state) = mode else {
            return nil
        }

        let lastAccepted = feedback.isAccepted
        if lastAccepted, let accepted = state.lastEmittedCandidate {
            valueState.sequence = accepted
            state.acceptedPairIndices.insert(state.pairIndex)
        }
        state.lastEmittedCandidate = nil
        guard let built = nextRedistributionProbe(state: &state, lastAccepted: lastAccepted) else {
            mode = .active(state)
            return nil
        }
        buffer = built
        state.lastEmittedCandidate = buffer
        let mutation = valueState.buildLeafValuesMutation(candidate: buffer)
        mode = .active(state)
        return .written(mutation: mutation, admission: .standard)
    }

    consuming func finish(reason _: ScopedStopReason, undelivered _: ScopedSearchFeedback?) -> ScopedSearchReport {
        ScopedSearchReport()
    }
}
