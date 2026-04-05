//
//  GraphRemovalEncoder.swift
//  Exhaust
//

// MARK: - Graph Removal Encoder

/// Removes containment-subtrees from the graph using adaptive batch sizing with head/tail alternation.
///
/// Operates in three modes based on the ``RemovalScope`` in the transformation:
/// - **Per-parent**: removes elements from a single sequence parent. Binary-searches batch size via ``FindIntegerStepper``, alternating tail-anchored and head-anchored deletions.
/// - **Subtree**: removes a single compound structural node. One probe.
/// - **Aligned**: removes corresponding elements across sibling sequences under a zip. Stub — full implementation in Phase 4.
///
/// This is an active-path operation: all target nodes have position ranges in the current sequence, so candidates are constructed via sequence surgery (``ChoiceSequence/removeSubranges(_:)``).
///
/// - SeeAlso: ``GraphDeletionEncoder``, ``AdaptiveDeletionEncoder``
struct GraphRemovalEncoder: GraphEncoder {
    let name: EncoderName = .graphDeletion

    // MARK: - State

    private var mode: Mode = .idle

    private enum Mode {
        case idle
        case perParent(PerParentState)
        case subtree(SubtreeState)
        case aligned
    }

    // MARK: - Per-Parent State

    private struct PerParentState {
        let sequence: ChoiceSequence
        var groups: [DeletionGroup]
        var groupIndex: Int
        var stepper: FindIntegerStepper
        var maxBatch: Int
        var needsNewGroup: Bool
        var didEmitCandidate: Bool
        var pendingHeadRetry: Bool
        var currentBatchSize: Int
        var bestAcceptedFromTail: Bool
    }

    private struct DeletionGroup {
        var candidates: [DeletionCandidate]
        var startIndex: Int
    }

    private struct DeletionCandidate {
        let nodeID: Int
        let positionRange: ClosedRange<Int>
    }

    // MARK: - Subtree State

    private struct SubtreeState {
        let sequence: ChoiceSequence
        let positionRange: ClosedRange<Int>
        var emitted: Bool
    }

    // MARK: - GraphEncoder

    mutating func start(scope: TransformationScope) {
        switch scope.transformation.operation {
        case let .removal(.perParent(perParentScope)):
            startPerParent(scope: perParentScope, sequence: scope.baseSequence, graph: scope.graph)
        case let .removal(.subtree(subtreeScope)):
            startSubtree(scope: subtreeScope, sequence: scope.baseSequence, graph: scope.graph)
        case .removal(.aligned):
            // Phase 4 — aligned removal not yet implemented.
            mode = .aligned
        default:
            mode = .idle
        }
    }

    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        switch mode {
        case .idle, .aligned:
            return nil
        case var .perParent(state):
            let result = nextPerParentProbe(state: &state, lastAccepted: lastAccepted)
            mode = .perParent(state)
            return result
        case var .subtree(state):
            let result = nextSubtreeProbe(state: &state)
            mode = .subtree(state)
            return result
        }
    }

    // MARK: - Per-Parent Mode

    private mutating func startPerParent(
        scope: PerParentRemovalScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) {
        var groups: [DeletionGroup] = []
        let candidates = scope.elementNodeIDs.compactMap { nodeID -> DeletionCandidate? in
            guard let range = graph.nodes[nodeID].positionRange else { return nil }
            return DeletionCandidate(nodeID: nodeID, positionRange: range)
        }.sorted { $0.positionRange.lowerBound < $1.positionRange.lowerBound }

        if candidates.isEmpty == false {
            groups.append(DeletionGroup(candidates: candidates, startIndex: 0))
        }

        // Sort groups by total subtree size descending.
        groups.sort { groupA, groupB in
            let sizeA = groupA.candidates.reduce(0) { $0 + $1.positionRange.count }
            let sizeB = groupB.candidates.reduce(0) { $0 + $1.positionRange.count }
            return sizeA > sizeB
        }

        mode = .perParent(PerParentState(
            sequence: sequence,
            groups: groups,
            groupIndex: 0,
            stepper: FindIntegerStepper(),
            maxBatch: 0,
            needsNewGroup: true,
            didEmitCandidate: false,
            pendingHeadRetry: false,
            currentBatchSize: 0,
            bestAcceptedFromTail: false
        ))
    }

    private func nextPerParentProbe(
        state: inout PerParentState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        while state.groupIndex < state.groups.count {
            if state.pendingHeadRetry {
                if let candidate = handlePendingHeadRetry(state: &state, lastAccepted: lastAccepted) {
                    return candidate
                }
                continue
            }

            if state.needsNewGroup {
                let group = state.groups[state.groupIndex]
                state.maxBatch = group.candidates.count - group.startIndex
                guard state.maxBatch > 0 else {
                    state.groupIndex += 1
                    continue
                }
                state.stepper = FindIntegerStepper()
                state.currentBatchSize = state.stepper.start()
                state.needsNewGroup = false
                state.didEmitCandidate = false
                state.bestAcceptedFromTail = false
                if let candidate = emitForBatchSize(state: &state, batchSize: state.currentBatchSize) {
                    return candidate
                }
                continue
            }

            let feedback = state.didEmitCandidate ? lastAccepted : false
            state.didEmitCandidate = false
            if feedback {
                state.bestAcceptedFromTail = false
            }
            if let nextSize = state.stepper.advance(lastAccepted: feedback) {
                state.currentBatchSize = nextSize
                if nextSize <= state.maxBatch,
                   let candidate = emitForBatchSize(state: &state, batchSize: nextSize) {
                    return candidate
                }
                continue
            }

            advancePastGroup(state: &state)
        }
        return nil
    }

    private func handlePendingHeadRetry(
        state: inout PerParentState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        state.pendingHeadRetry = false
        let tailFeedback = state.didEmitCandidate ? lastAccepted : false
        state.didEmitCandidate = false

        if tailFeedback {
            state.bestAcceptedFromTail = true
            if let nextSize = state.stepper.advance(lastAccepted: true) {
                state.currentBatchSize = nextSize
                if let candidate = emitForBatchSize(state: &state, batchSize: nextSize) {
                    return candidate
                }
            } else {
                advancePastGroup(state: &state)
            }
            return nil
        }

        if let candidate = buildCandidate(state: state, batchSize: state.currentBatchSize, anchor: .head) {
            state.didEmitCandidate = true
            return candidate
        }

        if let nextSize = state.stepper.advance(lastAccepted: false) {
            state.currentBatchSize = nextSize
            if let candidate = emitForBatchSize(state: &state, batchSize: nextSize) {
                return candidate
            }
        } else {
            advancePastGroup(state: &state)
        }
        return nil
    }

    private func emitForBatchSize(
        state: inout PerParentState,
        batchSize: Int
    ) -> ChoiceSequence? {
        if batchSize < state.maxBatch {
            if let candidate = buildCandidate(state: state, batchSize: batchSize, anchor: .tail) {
                state.pendingHeadRetry = true
                state.didEmitCandidate = true
                return candidate
            }
        }
        if let candidate = buildCandidate(state: state, batchSize: batchSize, anchor: .head) {
            state.didEmitCandidate = true
            return candidate
        }
        return nil
    }

    private func advancePastGroup(state: inout PerParentState) {
        let accepted = state.stepper.bestAccepted
        if accepted > 0 {
            let skip = state.bestAcceptedFromTail ? state.maxBatch : accepted
            state.groups[state.groupIndex].startIndex += skip
            if state.groups[state.groupIndex].startIndex >= state.groups[state.groupIndex].candidates.count {
                state.groupIndex += 1
            }
        } else {
            state.groupIndex += 1
        }
        state.needsNewGroup = true
        state.pendingHeadRetry = false
    }

    // MARK: - Candidate Construction

    private enum DeletionAnchor { case head, tail }

    private func buildCandidate(
        state: PerParentState,
        batchSize: Int,
        anchor: DeletionAnchor
    ) -> ChoiceSequence? {
        guard batchSize > 0, batchSize <= state.maxBatch else { return nil }
        let group = state.groups[state.groupIndex]
        let start = group.startIndex
        let offset = switch anchor {
        case .head: 0
        case .tail: state.maxBatch - batchSize
        }
        var rangeSet = RangeSet<Int>()
        var index = 0
        while index < batchSize {
            let range = group.candidates[start + offset + index].positionRange
            rangeSet.insert(contentsOf: range.lowerBound ..< range.upperBound + 1)
            index += 1
        }
        var candidate = state.sequence
        candidate.removeSubranges(rangeSet)
        guard candidate.shortLexPrecedes(state.sequence) else { return nil }
        return candidate
    }

    // MARK: - Subtree Mode

    private mutating func startSubtree(
        scope: SubtreeRemovalScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) {
        guard let range = graph.nodes[scope.nodeID].positionRange else {
            mode = .idle
            return
        }
        mode = .subtree(SubtreeState(
            sequence: sequence,
            positionRange: range,
            emitted: false
        ))
    }

    private func nextSubtreeProbe(state: inout SubtreeState) -> ChoiceSequence? {
        guard state.emitted == false else { return nil }
        state.emitted = true
        var candidate = state.sequence
        let range = state.positionRange
        var rangeSet = RangeSet<Int>()
        rangeSet.insert(contentsOf: range.lowerBound ..< range.upperBound + 1)
        candidate.removeSubranges(rangeSet)
        guard candidate.shortLexPrecedes(state.sequence) else { return nil }
        return candidate
    }
}
