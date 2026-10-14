//
//  ScopedLockstepSearch.swift
//  Exhaust
//

// MARK: - Lockstep Search

/// Reduces same-typed sibling values in lockstep, moving all values in a group by the same delta simultaneously.
///
/// Each suffix window of a tandem group is searched independently to skip near-target leaders that would otherwise block the whole set. Preserves relative relationships between coupled leaves — the property may constrain siblings to be equal or related.
/// Matching characters in the same domain also try their target and case/decomposition simplifications across every occurrence together, before character suffix windows.
///
/// The delta magnitude is above the opacity boundary and requires predicate feedback to find.
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
        var lastEmittedCandidate: ChoiceSequence?
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
        if lastAccepted, let accepted = state.lastEmittedCandidate {
            valueState.sequence = accepted
        }
        state.lastEmittedCandidate = nil
        guard let built = nextLockstepProbe(state: &state, lastAccepted: lastAccepted) else {
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
