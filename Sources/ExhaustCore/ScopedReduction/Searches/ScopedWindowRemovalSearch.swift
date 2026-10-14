//
//  ScopedWindowRemovalSearch.swift
//  Exhaust
//

// MARK: - Window Removal Search

/// Grows a removal window from its interior, center, or both edges, finding the largest accepted deletion with ``FindIntegerStepper``.
///
/// Search steps follow the stepper: one through four, then doubling, then binary search. Rightward growth removes one element per step; outward growth starts with the middle element or pair and adds one element on each side per step. Symmetric growth removes equal-sized prefix and suffix chunks atomically. A step beyond the window's capacity counts as a rejection without being probed.
///
/// Each probe removes a nested set from the dispatch-time base sequence, so every probe after an acceptance removes a superset of what was committed. The search therefore keeps going after an acceptance, and needs nothing from the recovered sequence.
struct ScopedWindowRemovalSearch: ScopedSearch {
    private var state: WindowState?

    private struct WindowState {
        let scope: WindowRemovalScope
        let baseSequence: ChoiceSequence
        let graph: ChoiceGraph
        var stepper = FindIntegerStepper()
        /// False until the first probe is emitted. The first pull carries no feedback, so it starts the stepper instead of advancing it.
        var awaitingFeedback = false
    }

    init(scope: WindowRemovalScope, baseSequence: ChoiceSequence, graph: ChoiceGraph) {
        guard scope.elementNodeIDs.isEmpty == false else {
            state = nil
            return
        }
        state = WindowState(scope: scope, baseSequence: baseSequence, graph: graph)
    }

    mutating func next(_ feedback: ScopedSearchFeedback, into buffer: inout ChoiceSequence) -> ScopedCandidate? {
        guard var current = state else {
            return nil
        }

        var proposal: Int? = current.awaitingFeedback
            ? current.stepper.advance(lastAccepted: feedback.isAccepted)
            : current.stepper.start()

        while let step = proposal {
            if let elementNodeIDs = current.scope.removalNodeIDs(step: step),
               let built = Self.candidate(removing: elementNodeIDs, state: current)
            {
                current.awaitingFeedback = true
                state = current
                buffer = built
                return .written(
                    mutation: .sequenceElementsRemoved([(
                        seqNodeID: current.scope.sequenceNodeID,
                        removedNodeIDs: elementNodeIDs
                    )]),
                    admission: .standard
                )
            }
            proposal = current.stepper.advance(lastAccepted: false)
        }

        state = nil
        return nil
    }

    consuming func finish(reason _: ScopedStopReason, undelivered _: ScopedSearchFeedback?) -> ScopedSearchReport {
        ScopedSearchReport()
    }

    // MARK: - Helpers

    private static func candidate(removing elementNodeIDs: [Int], state: WindowState) -> ChoiceSequence? {
        let elementScope = ElementRemovalScope(
            targets: [SequenceRemovalTarget(
                sequenceNodeID: state.scope.sequenceNodeID,
                elementNodeIDs: elementNodeIDs
            )],
            maxBatch: elementNodeIDs.count,
            maxElementYield: 0
        )
        return ScopedStructuralCandidates.elementRemoval(
            elementScope,
            sequence: state.baseSequence,
            graph: state.graph
        )
    }
}
