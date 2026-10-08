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

    /// Describes a suffix window to probe: which node indices to target, the direction of movement, and the shortlex distance to try.
    struct LockstepWindowPlan {
        let windowIndices: [Int]
        let tag: TypeTag
        let originalEntries: [(index: Int, entry: ChoiceSequenceValue)]
        let searchUpward: Bool
        let distance: UInt64
        let usesFloatingSteps: Bool
    }

    /// Tracks whether the encoder is in the direct-shot phase (full distance) or binary search refinement.
    enum LockstepProbePhase {
        case directShot
        case binarySearchStart
        case binarySearch
    }

    /// Holds the per-scope mutable state for the lockstep encoder's probe loop, including plan iteration and binary search progress.
    struct LockstepState {
        var plans: [LockstepWindowPlan]
        var planIndex: Int
        var probePhase: LockstepProbePhase
        var stepper: BinarySearchStepper
        var lastEmittedCandidate: ChoiceSequence?
        var lastWasDirectShot: Bool
    }

    // MARK: - GraphEncoder

    mutating func start(scope: EncoderInput) {
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

    mutating func nextProbe(into candidate: inout ChoiceSequence, lastAccepted: Bool) -> EncoderProbe? {
        guard case var .active(state) = mode else { return nil }

        if lastAccepted, let accepted = state.lastEmittedCandidate {
            valueState.sequence = accepted
        }
        state.lastEmittedCandidate = nil
        guard let built = nextLockstepProbe(state: &state, lastAccepted: lastAccepted) else {
            mode = .active(state)
            return nil
        }
        candidate = built
        state.lastEmittedCandidate = candidate
        let mutation = valueState.buildLeafValuesMutation(candidate: candidate)
        mode = .active(state)
        return mutation
    }
}
