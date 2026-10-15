//
//  ScopedLockstepSearch.swift
//  Exhaust
//

// MARK: - Lockstep Search

/// Reduces same-typed sibling values in lockstep, moving all values in a group by the same delta simultaneously.
///
/// Moving every value by the same delta preserves relationships the property may impose between siblings, such as equality. Each suffix window of a tandem group is searched independently, so a near-target leader cannot block the rest of the group. Matching characters in the same domain also try their target and case or decomposition simplifications across every occurrence together, before character suffix windows.
///
/// The graph cannot predict which delta keeps the property failing (the delta lies above the opacity boundary), so only property feedback can find it.
///
/// Candidate construction lives in `ScopedLockstepSearch+Probing.swift`.
struct ScopedLockstepSearch: ScopedSearch {
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

    enum LockstepPlan {
        case shift(LockstepWindowPlan)
        case characters(indices: [Int], candidates: [UInt64])
    }

    /// Tracks whether the search is in the direct-shot phase (full distance) or binary search refinement.
    enum LockstepProbePhase {
        case directShot
        case binarySearchStart
        case binarySearch
    }

    /// Holds the per-scope mutable state for the lockstep search, including plan iteration and binary search progress.
    struct LockstepState {
        var plans: [LockstepPlan]
        var planIndex: Int
        var characterCandidateIndex: Int
        var probePhase: LockstepProbePhase
        var stepper: BinarySearchStepper
        /// Whether the last probe was the plan's full-distance direct shot. An accepted direct shot cannot be improved, so the plan ends.
        var lastWasDirectShot: Bool
    }

    // MARK: - Search

    /// Plans suffix windows and character simplifications for every group in `scope` against `sequence`, at most `maxSuffixWindows` suffix windows per group.
    init(scope: TandemScope, sequence: ChoiceSequence, graph: ChoiceGraph, maxSuffixWindows: Int) {
        valueState.reset(sequence: sequence)
        for group in scope.groups {
            for entry in group.leaves {
                valueState.registerLeaf(nodeID: entry.nodeID, mayReshape: entry.mayReshapeOnAcceptance, graph: graph)
            }
        }
        startLockstep(scope: scope, graph: graph, maxSuffixWindows: maxSuffixWindows)
    }

    mutating func next(_ feedback: ScopedSearchFeedback, into buffer: inout ChoiceSequence) -> ScopedCandidate? {
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
        }
        guard let built = nextLockstepProbe(state: &state, lastAccepted: lastAccepted) else {
            mode = .active(state)
            return nil
        }
        buffer = built
        let mutation = valueState.buildLeafValuesMutation(candidate: buffer)
        mode = .active(state)
        return .written(mutation: mutation, admission: .standard)
    }
}
