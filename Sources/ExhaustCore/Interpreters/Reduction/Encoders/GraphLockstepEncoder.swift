//
//  GraphLockstepEncoder.swift
//  Exhaust
//

// MARK: - Graph Lockstep Encoder

/// Reduces same-typed sibling values in lockstep, moving all values in a group by the same delta simultaneously.
///
/// Each suffix window of a tandem group is searched independently to skip near-target leaders that would otherwise block the whole set. Preserves relative relationships between coupled leaves — the property may constrain siblings to be equal or related.
///
/// This is a value encoder: the delta magnitude is above the opacity boundary and requires predicate feedback to find.
///
/// Candidate construction lives in `GraphLockstepEncoder+Probing.swift`.
struct GraphLockstepEncoder: GraphEncoder {
    let name: EncoderName = .lockstep

    // MARK: - State

    var valueState = ValueEncoderState()
    var mode: Mode = .idle

    enum Mode {
        case idle
        case active(LockstepState)
    }

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
        var lastWasDirectShot: Bool
    }

    // MARK: - GraphEncoder

    mutating func start(scope: TransformationScope) {
        valueState.reset(sequence: scope.baseSequence)
        mode = .idle

        guard case let .exchange(.tandem(tandemScope)) = scope.transformation.operation else {
            return
        }

        let graph = scope.graph
        for group in tandemScope.groups {
            for entry in group.leaves {
                valueState.registerLeaf(nodeID: entry.nodeID, mayReshape: entry.mayReshapeOnAcceptance, graph: graph)
            }
        }
        startLockstep(scope: tandemScope, graph: graph)
    }

    mutating func refreshScope(graph: ChoiceGraph, sequence newSequence: ChoiceSequence) {
        valueState.reset(sequence: newSequence)
        mode = .idle

        let scopes = ExchangeScopeQuery.build(graph: graph)
        guard let tandem = scopes.firstNonNil({ scope -> TandemScope? in
            if case let .tandem(inner) = scope { return inner }
            return nil
        }) else { return }
        for group in tandem.groups {
            for entry in group.leaves {
                valueState.registerLeaf(nodeID: entry.nodeID, mayReshape: entry.mayReshapeOnAcceptance, graph: graph)
            }
        }
        startLockstep(scope: tandem, graph: graph)
    }

    mutating func nextProbe(lastAccepted: Bool) -> EncoderProbe? {
        guard case var .active(state) = mode else { return nil }

        if lastAccepted, let accepted = state.lastEmittedCandidate {
            valueState.sequence = accepted
        }
        state.lastEmittedCandidate = nil
        guard let candidate = nextLockstepProbe(state: &state, lastAccepted: lastAccepted) else {
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
