//
//  GraphExchangeEncoder.swift
//  Exhaust
//

// MARK: - Graph Exchange Encoder

/// Moves magnitude between leaves to enable future structural operations.
///
/// Operates in two modes based on the ``ExchangeScope``:
/// - **Redistribution**: for each source-receiver pair, binary-searches on delta magnitude via ``MaxBinarySearchStepper`` to find the largest accepted transfer. The graph determines which pairs; the encoder determines how much.
/// - **Tandem**: lockstep reduction of same-typed sibling values. Each suffix window of a tandem group is searched independently to skip near-target leaders.
///
/// This is a value encoder: the delta magnitude is above the opacity boundary and requires predicate feedback to find.
///
/// The redistribution and lockstep implementations live in `GraphExchangeEncoder+Redistribution.swift` and `GraphExchangeEncoder+Lockstep.swift`. The cross-type and floating-point arithmetic that backs redistribution lives in `GraphExchangeEncoder+RationalMath.swift`. State types are nested here so all extensions can reference them.
struct GraphExchangeEncoder: GraphEncoder {
    let name: EncoderName = .graphRedistribution

    // MARK: - State

    var mode: Mode = .idle
    var sequence: ChoiceSequence = .init()
    /// Maps the sequence index of every leaf the current scope can touch to its graph node ID and bind-inner reshape marker. Built once at ``start(scope:)`` time and read by ``nextProbe(lastAccepted:)`` to construct ``ProjectedMutation/leafValues(_:)`` reports without diffing the entire sequence.
    var leafLookup: [Int: (nodeID: Int, mayReshape: Bool)] = [:]
    /// The original scope kind seen at ``start(scope:)`` time. Stored so ``refreshScope(graph:sequence:)`` can re-derive a fresh exchange scope from the live graph against the same kind (redistribution vs tandem) when an in-pass structural mutation invalidates the cached pair / lockstep state. The current redistribution and lockstep states are not preserved across a refresh because their pair indices reference pre-mutation positions; the refresh re-builds them from scratch via ``ChoiceGraph/exchangeScopes()``.
    var originalExchangeKind: ExchangeScopeKind = .none

    /// Discriminator for which exchange scope shape the encoder was started against. Used by ``refreshScope(graph:sequence:)`` to find the corresponding scope in the live graph's ``ChoiceGraph/exchangeScopes()`` result.
    enum ExchangeScopeKind {
        case none
        case redistribution
        case lockstep
    }

    enum Mode {
        case idle
        case redistribution(RedistributionState)
        case lockstep(LockstepState)
    }

    /// A single window plan for lockstep reduction.
    ///
    /// Each plan is a suffix of an index set with the same ``TypeTag``. Suffix windows let the encoder skip a near-target leader that would otherwise block the whole set.
    struct LockstepWindowPlan {
        let windowIndices: [Int]
        let tag: TypeTag
        let originalEntries: [(index: Int, entry: ChoiceSequenceValue)]
        let searchUpward: Bool
        let distance: UInt64
        let usesFloatingSteps: Bool
    }

    enum LockstepProbePhase {
        case directShot
        case binarySearchStart
        case binarySearch
    }

    struct LockstepState {
        var plans: [LockstepWindowPlan]
        var planIndex: Int
        var probePhase: LockstepProbePhase
        var stepper: MaxBinarySearchStepper
        var lastEmittedCandidate: ChoiceSequence?
        /// Whether the last emitted candidate was a direct shot (skip binary search on acceptance).
        var lastWasDirectShot: Bool
    }

    /// Rational-arithmetic context for cross-type or float redistribution.
    ///
    /// Both sides are represented as numerators over a common denominator. ``intStepSize`` is `denominator` when at least one side is an integer (forcing integer-step deltas), otherwise 1.
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
        /// Whether the full-delta probe has been tried for the current pair.
        var triedFullDelta: Bool
        /// Pair indices that had at least one accepted probe this pass. Only these are re-evaluated on the next pass.
        var acceptedPairIndices: Set<Int>
        /// Number of completed passes (capped at ``maxPasses`` to bound work).
        var passCount: Int
        /// Which pair indices to evaluate on the current pass. Nil means all pairs.
        var activePairIndices: Set<Int>?
    }

    /// Maximum number of redistribution passes before the encoder stops re-evaluating pairs. With targeted re-evaluation (only accepted pairs), subsequent passes are cheap — O(log maxDelta) probes per accepted pair. The investigation doc proposed cutting this to 1 as Fix C, but bisection (16 → 8 → 1) showed that 16 is the optimum: at maxPasses=8 Bound5 already regresses (+8% mats, +6% reduce time, −7% accepts) because some pair binary searches need 9–16 passes to converge, and at maxPasses=1 the regression is catastrophic (+143% mats, +129% reduce time). All other workloads complete pair convergence in ≤1 pass, so the multi-pass replay is inert there — it adds zero cost where it isn't needed and is load-bearing where it is.
    static let maxPasses = 16

    /// Cap on the number of redistribution pairs probed per scope. Bisection (240 → 120 → 60 → 30 → 16) located the inflection between 30 and 16. At cap=30 ComplexGrammar reached 27,716 ms (vs Bonsai's ~33,000 ms and the cap=240 baseline of ~30,000 ms); at cap=16 it crept back up to 27,830 ms with no compensating benefit. Bound5 acc loss at cap=30 was functionally invisible (no CE quality change, no reduce time change, same canonical CE) — the lost accepts were trailing-edge progress that did not change the eventual outcome. Bonsai's ``RedistributeAcrossValueContainersEncoder`` uses 240 in its `estimatedCost`, but Graph's per-probe cost profile and outer reducer scheduling make 30 the right value here.
    static let maxPairsPerScope = 30

    // MARK: - GraphEncoder

    mutating func start(scope: TransformationScope) {
        sequence = scope.baseSequence
        mode = .idle
        leafLookup = [:]
        originalExchangeKind = .none

        guard case let .exchange(exchangeScope) = scope.transformation.operation else {
            return
        }

        let graph = scope.graph
        populateLeafLookup(from: exchangeScope, graph: graph)

        switch exchangeScope {
        case let .redistribution(redistScope):
            originalExchangeKind = .redistribution
            startRedistribution(scope: redistScope, graph: graph)
        case let .tandem(tandemScope):
            originalExchangeKind = .lockstep
            startLockstep(scope: tandemScope, graph: graph)
        }
    }

    mutating func refreshScope(graph: ChoiceGraph, sequence newSequence: ChoiceSequence) {
        // Re-derive the encoder's working set from the live graph after a
        // structural mutation. The pair list (RedistributionState) and the
        // lockstep plans (LockstepState) reference pre-mutation graph node
        // IDs and sequence positions; without a refresh the next probe
        // would address tombstoned nodes or shifted-out positions. The
        // refresh discards in-flight pair / plan state, replays the live
        // graph through ``ChoiceGraph/exchangeScopes()``, and re-runs the
        // appropriate ``startRedistribution`` / ``startLockstep`` against
        // the live state. New leaves the splice created enter the new
        // pair list naturally because ``exchangeScopes()`` walks the
        // current ``typeCompatibilityEdges`` set.
        sequence = newSequence
        mode = .idle
        leafLookup = [:]

        guard originalExchangeKind != .none else { return }

        let scopes = graph.exchangeScopes()
        switch originalExchangeKind {
        case .none:
            return
        case .redistribution:
            let redistribution = scopes.firstNonNil { scope -> RedistributionScope? in
                if case let .redistribution(inner) = scope { return inner }
                return nil
            }
            guard let redistribution else { return }
            populateLeafLookup(from: .redistribution(redistribution), graph: graph)
            startRedistribution(scope: redistribution, graph: graph)
        case .lockstep:
            let tandem = scopes.firstNonNil { scope -> TandemScope? in
                if case let .tandem(inner) = scope { return inner }
                return nil
            }
            guard let tandem else { return }
            populateLeafLookup(from: .tandem(tandem), graph: graph)
            startLockstep(scope: tandem, graph: graph)
        }
    }

    /// Builds the (sequence index → nodeID, mayReshape) lookup once for both redistribution and lockstep modes. The wrapping ``nextProbe(lastAccepted:)`` reads it to construct ``ProjectedMutation/leafValues(_:)`` reports.
    mutating func populateLeafLookup(from exchangeScope: ExchangeScope, graph: ChoiceGraph) {
        switch exchangeScope {
        case let .redistribution(redistScope):
            for pair in redistScope.pairs {
                if let range = graph.nodes[pair.source.nodeID].positionRange {
                    leafLookup[range.lowerBound] = (pair.source.nodeID, pair.source.mayReshapeOnAcceptance)
                }
                if let range = graph.nodes[pair.sink.nodeID].positionRange {
                    leafLookup[range.lowerBound] = (pair.sink.nodeID, pair.sink.mayReshapeOnAcceptance)
                }
            }
        case let .tandem(tandemScope):
            for group in tandemScope.groups {
                for entry in group.leaves {
                    if let range = graph.nodes[entry.nodeID].positionRange {
                        leafLookup[range.lowerBound] = (entry.nodeID, entry.mayReshapeOnAcceptance)
                    }
                }
            }
        }
    }

    mutating func nextProbe(lastAccepted: Bool) -> EncoderProbe? {
        switch mode {
        case .idle:
            return nil
        case var .redistribution(state):
            // Update baseline on acceptance.
            if lastAccepted, let accepted = state.lastEmittedCandidate {
                sequence = accepted
                state.acceptedPairIndices.insert(state.pairIndex)
            }
            state.lastEmittedCandidate = nil
            guard let candidate = nextRedistributionProbe(state: &state, lastAccepted: lastAccepted) else {
                mode = .redistribution(state)
                return nil
            }
            mode = .redistribution(state)
            return EncoderProbe(
                candidate: candidate,
                mutation: buildLeafValuesMutation(candidate: candidate)
            )
        case var .lockstep(state):
            if lastAccepted, let accepted = state.lastEmittedCandidate {
                sequence = accepted
            }
            state.lastEmittedCandidate = nil
            guard let candidate = nextLockstepProbe(state: &state, lastAccepted: lastAccepted) else {
                mode = .lockstep(state)
                return nil
            }
            mode = .lockstep(state)
            return EncoderProbe(
                candidate: candidate,
                mutation: buildLeafValuesMutation(candidate: candidate)
            )
        }
    }

    /// Constructs a `.leafValues` mutation report by walking ``leafLookup`` and recording each entry whose value differs between the candidate and the current baseline.
    func buildLeafValuesMutation(candidate: ChoiceSequence) -> ProjectedMutation {
        var changes: [LeafChange] = []
        for (sequenceIndex, info) in leafLookup {
            guard sequenceIndex < candidate.count, sequenceIndex < sequence.count else { continue }
            guard let candidateChoice = candidate[sequenceIndex].value?.choice,
                  let baselineChoice = sequence[sequenceIndex].value?.choice
            else { continue }
            guard candidateChoice != baselineChoice else { continue }
            changes.append(LeafChange(
                leafNodeID: info.nodeID,
                newValue: candidateChoice,
                mayReshape: info.mayReshape
            ))
        }
        return .leafValues(changes)
    }
}
