//
//  GraphRedistributionEncoder.swift
//  Exhaust
//

// MARK: - Graph Redistribution Encoder

/// Moves magnitude between type-compatible leaf pairs to enable future structural operations.
///
/// For each source-receiver pair, binary-searches on delta magnitude via ``MaxBinarySearchStepper`` to find the largest accepted transfer. The graph determines which pairs; the encoder determines how much. Up to ``maxPasses`` replay passes re-evaluate accepted pairs for further convergence.
///
/// This is a value encoder: the delta magnitude is above the opacity boundary and requires predicate feedback to find.
///
/// Candidate construction and rational-arithmetic helpers live in `GraphRedistributionEncoder+Probing.swift` and `GraphRedistributionEncoder+RationalMath.swift`.
struct GraphRedistributionEncoder: GraphEncoder {
    let name: EncoderName = .graphRedistribution

    // MARK: - State

    var valueState = ValueEncoderState()
    var mode: Mode = .idle

    enum Mode {
        case idle
        case active(RedistributionState)
    }

    struct MixedRedistributionContext {
        let sourceNumerator: Int64
        let sinkNumerator: Int64
        let denominator: UInt64
        let intStepSize: UInt64
        let sourceMovesUpward: Bool
        let distanceInSteps: UInt64
    }

    struct RedistributionState {
        let pairs: [(sourceIndex: Int, sinkIndex: Int, sourceTag: TypeTag, sinkTag: TypeTag, maxDelta: UInt64, mixedContext: MixedRedistributionContext?)]
        var pairIndex: Int
        var stepper: MaxBinarySearchStepper?
        var didEmitCandidate: Bool
        var lastEmittedCandidate: ChoiceSequence?
        var triedFullDelta: Bool
        var acceptedPairIndices: Set<Int>
        var passCount: Int
        var activePairIndices: Set<Int>?
    }

    /// Maximum number of redistribution passes before the encoder stops re-evaluating pairs.
    static let maxPasses = 16

    /// Cap on the number of redistribution pairs probed per scope.
    static let maxPairsPerScope = 30

    // MARK: - GraphEncoder

    mutating func start(scope: TransformationScope) {
        valueState.reset(sequence: scope.baseSequence)
        mode = .idle

        guard case let .exchange(.redistribution(redistScope)) = scope.transformation.operation else {
            return
        }

        let graph = scope.graph
        for pair in redistScope.pairs {
            valueState.registerLeaf(nodeID: pair.source.nodeID, mayReshape: pair.source.mayReshapeOnAcceptance, graph: graph)
            valueState.registerLeaf(nodeID: pair.sink.nodeID, mayReshape: pair.sink.mayReshapeOnAcceptance, graph: graph)
        }
        startRedistribution(scope: redistScope, graph: graph)
    }

    mutating func refreshScope(graph: ChoiceGraph, sequence newSequence: ChoiceSequence) {
        valueState.reset(sequence: newSequence)
        mode = .idle

        let scopes = ExchangeScopeQuery.build(graph: graph)
        guard let redistribution = scopes.firstNonNil({ scope -> RedistributionScope? in
            if case let .redistribution(inner) = scope { return inner }
            return nil
        }) else { return }
        for pair in redistribution.pairs {
            valueState.registerLeaf(nodeID: pair.source.nodeID, mayReshape: pair.source.mayReshapeOnAcceptance, graph: graph)
            valueState.registerLeaf(nodeID: pair.sink.nodeID, mayReshape: pair.sink.mayReshapeOnAcceptance, graph: graph)
        }
        startRedistribution(scope: redistribution, graph: graph)
    }

    mutating func nextProbe(lastAccepted: Bool) -> EncoderProbe? {
        guard case var .active(state) = mode else { return nil }

        if lastAccepted, let accepted = state.lastEmittedCandidate {
            valueState.sequence = accepted
            state.acceptedPairIndices.insert(state.pairIndex)
        }
        state.lastEmittedCandidate = nil
        guard let candidate = nextRedistributionProbe(state: &state, lastAccepted: lastAccepted) else {
            mode = .active(state)
            return nil
        }
        mode = .active(state)
        return EncoderProbe(
            candidate: candidate,
            mutation: valueState.buildLeafValuesMutation(candidate: candidate)
        )
    }
}
