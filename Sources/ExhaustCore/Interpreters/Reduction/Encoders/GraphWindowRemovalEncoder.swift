//
//  GraphWindowRemovalEncoder.swift
//  Exhaust
//

// MARK: - Graph Window Removal Encoder

/// Grows a removal window rightward from an interior element, finding the longest removable run with ``FindIntegerStepper``.
///
/// Probe lengths follow the stepper: one through four, then doubling, then binary search between the longest accepted length and the shortest rejected one. A length beyond the window's capacity counts as a rejection without being probed.
///
/// Each probe removes a prefix of ``WindowRemovalScope/elementNodeIDs`` from the dispatch-time base sequence, and accepted lengths only increase, so every probe after an acceptance removes a superset of what was committed. The reported mutation is never applied to the live graph; the session's rebuild picks up the final state.
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

        while let length = proposal {
            if length <= current.scope.elementNodeIDs.count,
               let built = buildCandidate(length: length, state: current)
            {
                current.awaitingFeedback = true
                state = current
                candidate = built
                return .sequenceElementsRemoved([(
                    seqNodeID: current.scope.sequenceNodeID,
                    removedNodeIDs: Array(current.scope.elementNodeIDs[..<length])
                )])
            }
            proposal = current.stepper.advance(lastAccepted: false)
        }

        state = nil
        return nil
    }

    // MARK: - Candidate Construction

    private func buildCandidate(length: Int, state: WindowState) -> ChoiceSequence? {
        let elementScope = ElementRemovalScope(
            targets: [SequenceRemovalTarget(
                sequenceNodeID: state.scope.sequenceNodeID,
                elementNodeIDs: Array(state.scope.elementNodeIDs[..<length])
            )],
            maxBatch: length,
            maxElementYield: 0
        )
        return GraphStructuralEncoder.buildElementCandidate(
            scope: elementScope,
            sequence: state.baseSequence,
            graph: state.graph
        )
    }
}
