//
//  GraphWindowRemovalEncoder.swift
//  Exhaust
//

// MARK: - Graph Window Removal Encoder

/// Grows a removal window from its interior, center, or both edges, finding the largest accepted deletion with ``FindIntegerStepper``.
///
/// Search steps follow the stepper: one through four, then doubling, then binary search. Rightward growth removes one element per step; outward growth starts with the middle element or pair and adds one element on each side per step. Symmetric growth removes equal-sized prefix and suffix chunks atomically. A step beyond the window's capacity counts as a rejection without being probed.
///
/// Each probe removes a nested set from the dispatch-time base sequence, so every probe after an acceptance removes a superset of what was committed. The reported mutation is never applied to the live graph; the session's rebuild picks up the final state.
struct GraphWindowRemovalEncoder: GraphEncoder {
    let name: EncoderName = .deletion

    /// The stepper keeps growing the window after an accepted length, so the session must survive acceptance. Probes are built from the dispatch-time base, which stays valid after acceptance, so nothing needs refreshing.
    let acceptanceHandling: AcceptanceHandling = .refreshAndIdle

    // MARK: - State

    private var state: WindowState?

    private struct WindowState {
        let scope: WindowRemovalScope
        let baseSequence: ChoiceSequence
        let graph: ChoiceGraph
        var stepper = FindIntegerStepper()
        /// False until the first probe is emitted. The first ``GraphWindowRemovalEncoder/nextProbe(into:lastAccepted:)`` call carries no feedback, so it starts the stepper instead of advancing it.
        var awaitingFeedback = false
    }

    // MARK: - GraphEncoder

    mutating func start(scope: EncoderInput) {
        state = nil
        guard case let .remove(.window(windowScope)) = scope.transformation.operation,
              windowScope.elementNodeIDs.isEmpty == false
        else {
            return
        }
        state = WindowState(
            scope: windowScope,
            baseSequence: scope.baseSequence,
            graph: scope.graph
        )
    }

    mutating func nextProbe(into candidate: inout ChoiceSequence, lastAccepted: Bool) -> EncoderProbe? {
        guard var current = state else {
            return nil
        }

        var proposal: Int? = current.awaitingFeedback
            ? current.stepper.advance(lastAccepted: lastAccepted)
            : current.stepper.start()

        while let step = proposal {
            if let elementNodeIDs = current.scope.removalNodeIDs(step: step),
               let built = buildCandidate(elementNodeIDs: elementNodeIDs, state: current)
            {
                current.awaitingFeedback = true
                state = current
                candidate = built
                return .sequenceElementsRemoved([(
                    seqNodeID: current.scope.sequenceNodeID,
                    removedNodeIDs: elementNodeIDs
                )])
            }
            proposal = current.stepper.advance(lastAccepted: false)
        }

        state = nil
        return nil
    }

    // MARK: - Candidate Construction

    private func buildCandidate(elementNodeIDs: [Int], state: WindowState) -> ChoiceSequence? {
        let elementScope = ElementRemovalScope(
            targets: [SequenceRemovalTarget(
                sequenceNodeID: state.scope.sequenceNodeID,
                elementNodeIDs: elementNodeIDs
            )],
            maxBatch: elementNodeIDs.count,
            maxElementYield: 0
        )
        return GraphStructuralEncoder.buildElementCandidate(
            scope: elementScope,
            sequence: state.baseSequence,
            graph: state.graph
        )
    }
}
