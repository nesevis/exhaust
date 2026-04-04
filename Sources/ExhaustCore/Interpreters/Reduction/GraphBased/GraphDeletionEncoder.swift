//
//  GraphDeletionEncoder.swift
//  Exhaust
//

// MARK: - Graph Deletion Encoder

/// Deletes sequence element nodes using adaptive batch sizing with head/tail alternation.
///
/// Groups deletable nodes by their parent sequence node, then within each group uses ``FindIntegerStepper`` to binary-search for the optimal batch size. At each batch size, a tail-anchored deletion is tried first, then head-anchored on rejection. This preserves useful content at either end of a sequence — for example, in `[empty, important]`, head-anchored deletion removes the empty element while tail-anchored deletion would remove the important one.
///
/// - Complexity: O(*g* . log *n*) probes where *g* is the number of sequence parent groups and *n* is the maximum group size.
/// - SeeAlso: ``AdaptiveDeletionEncoder``, ``AntichainDeletionEncoder``
public struct GraphDeletionEncoder: GraphEncoder {
    public let name: EncoderName = .graphDeletion

    // MARK: - State

    private var sequence = ChoiceSequence()

    /// Candidates grouped by parent sequence node, ordered by position.
    private var groups: [DeletionGroup] = []
    private var groupIndex = 0

    /// Adaptive batch sizing within each group.
    private var stepper = FindIntegerStepper()
    private var maxBatch = 0
    private var needsNewGroup = true
    private var didEmitCandidate = false

    /// When true, a tail-anchored candidate was emitted for `currentBatchSize`
    /// and we should try the head anchor before advancing the stepper.
    private var pendingHeadRetry = false

    /// The batch size currently being probed (retained across the tail/head alternation).
    private var currentBatchSize = 0

    /// Whether the stepper's best accepted result came from a tail-anchored deletion.
    /// Determines group advancement: head-accepted advances past head elements,
    /// tail-accepted skips the entire group.
    private var bestAcceptedFromTail = false

    private struct DeletionGroup {
        /// Candidates in this group, ordered by position.
        var candidates: [DeletionCandidate]
        /// Index into `candidates` for the current batch start.
        var startIndex: Int
    }

    private struct DeletionCandidate {
        let nodeID: Int
        let positionRange: ClosedRange<Int>
    }

    // MARK: - GraphEncoder

    public mutating func start(
        graph: ChoiceGraph,
        sequence: ChoiceSequence,
        tree _: ChoiceTree
    ) {
        self.sequence = sequence
        groups = []
        groupIndex = 0
        needsNewGroup = true
        didEmitCandidate = false
        pendingHeadRetry = false
        currentBatchSize = 0
        bestAcceptedFromTail = false

        // Collect deletable nodes grouped by parent sequence node.
        var parentGroups: [Int: [DeletionCandidate]] = [:]

        for node in graph.nodes {
            guard node.positionRange != nil else { continue }
            guard let parentID = node.parent else { continue }
            guard case let .sequence(metadata) = graph.nodes[parentID].kind else { continue }

            // Respect minimum length constraint.
            let minLength = metadata.lengthConstraint?.lowerBound ?? 0
            guard UInt64(metadata.elementCount) > minLength else { continue }

            guard let range = node.positionRange else { continue }
            parentGroups[parentID, default: []].append(
                DeletionCandidate(nodeID: node.id, positionRange: range)
            )
        }

        // Sort each group's candidates by position (ascending) for consistent head/tail semantics.
        // Sort groups by total subtree size descending — largest reduction potential first.
        groups = parentGroups.values.map { candidates in
            DeletionGroup(
                candidates: candidates.sorted { $0.positionRange.lowerBound < $1.positionRange.lowerBound },
                startIndex: 0
            )
        }.sorted { groupA, groupB in
            let sizeA = groupA.candidates.reduce(0) { $0 + $1.positionRange.count }
            let sizeB = groupB.candidates.reduce(0) { $0 + $1.positionRange.count }
            return sizeA > sizeB
        }
    }

    public mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        while groupIndex < groups.count {
            // A tail candidate was emitted last time. Process its feedback
            // and try the head anchor if the tail was rejected.
            if pendingHeadRetry {
                if let candidate = handlePendingHeadRetry(lastAccepted: lastAccepted) {
                    return candidate
                }
                continue
            }

            if needsNewGroup {
                let group = groups[groupIndex]
                maxBatch = group.candidates.count - group.startIndex
                guard maxBatch > 0 else {
                    groupIndex += 1
                    continue
                }
                stepper = FindIntegerStepper()
                currentBatchSize = stepper.start()
                needsNewGroup = false
                didEmitCandidate = false
                bestAcceptedFromTail = false
                if let candidate = emitForBatchSize(currentBatchSize) {
                    return candidate
                }
                continue
            }

            // Use actual lastAccepted only if we emitted a candidate last time.
            let feedback = didEmitCandidate ? lastAccepted : false
            didEmitCandidate = false
            if feedback {
                bestAcceptedFromTail = false
            }
            if let nextSize = stepper.advance(lastAccepted: feedback) {
                currentBatchSize = nextSize
                if nextSize <= maxBatch, let candidate = emitForBatchSize(nextSize) {
                    return candidate
                }
                // Batch size exceeded group or produced no candidate — loop back
                // to advance the stepper with a rejection on next iteration.
                continue
            }

            advancePastGroup()
        }
        return nil
    }

    // MARK: - Tail/Head Alternation

    /// Processes feedback for a tail-anchored candidate and tries head if tail was rejected.
    private mutating func handlePendingHeadRetry(lastAccepted: Bool) -> ChoiceSequence? {
        pendingHeadRetry = false
        let tailFeedback = didEmitCandidate ? lastAccepted : false
        didEmitCandidate = false

        if tailFeedback {
            bestAcceptedFromTail = true
            if let nextSize = stepper.advance(lastAccepted: true) {
                currentBatchSize = nextSize
                if let candidate = emitForBatchSize(nextSize) {
                    return candidate
                }
            } else {
                advancePastGroup()
            }
            return nil
        }

        // Tail was rejected. Try head for the same batch size.
        if let candidate = buildCandidate(batchSize: currentBatchSize, anchor: .head) {
            didEmitCandidate = true
            return candidate
        }

        if let nextSize = stepper.advance(lastAccepted: false) {
            currentBatchSize = nextSize
            if let candidate = emitForBatchSize(nextSize) {
                return candidate
            }
        } else {
            advancePastGroup()
        }
        return nil
    }

    /// Tries to emit a candidate for the given batch size: tail first, then head.
    private mutating func emitForBatchSize(_ batchSize: Int) -> ChoiceSequence? {
        if batchSize < maxBatch {
            if let candidate = buildCandidate(batchSize: batchSize, anchor: .tail) {
                pendingHeadRetry = true
                didEmitCandidate = true
                return candidate
            }
        }
        if let candidate = buildCandidate(batchSize: batchSize, anchor: .head) {
            didEmitCandidate = true
            return candidate
        }
        return nil
    }

    /// Advances past the current group after the stepper converges.
    private mutating func advancePastGroup() {
        let accepted = stepper.bestAccepted
        if accepted > 0 {
            // Head-accepted: skip past the deleted head elements; remaining tail
            // elements form a new group. Tail-accepted: skip the entire group.
            let skip = bestAcceptedFromTail ? maxBatch : accepted
            groups[groupIndex].startIndex += skip
            if groups[groupIndex].startIndex >= groups[groupIndex].candidates.count {
                groupIndex += 1
            }
        } else {
            groupIndex += 1
        }
        needsNewGroup = true
        pendingHeadRetry = false
    }

    // MARK: - Anchor

    private enum DeletionAnchor { case head, tail }

    // MARK: - Candidate Construction

    private func buildCandidate(batchSize: Int, anchor: DeletionAnchor) -> ChoiceSequence? {
        guard batchSize > 0, batchSize <= maxBatch else { return nil }
        let group = groups[groupIndex]
        let start = group.startIndex
        let offset = switch anchor {
        case .head: 0
        case .tail: maxBatch - batchSize
        }
        var rangeSet = RangeSet<Int>()
        var index = 0
        while index < batchSize {
            let range = group.candidates[start + offset + index].positionRange
            rangeSet.insert(contentsOf: range.lowerBound ..< range.upperBound + 1)
            index += 1
        }
        var candidate = sequence
        candidate.removeSubranges(rangeSet)
        guard candidate.shortLexPrecedes(sequence) else { return nil }
        return candidate
    }
}
