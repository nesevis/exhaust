//
//  GraphDeletionEncoder.swift
//  Exhaust
//

// MARK: - Graph Deletion Encoder

/// Deletes structural boundary nodes via delta-debugging over the graph's deletion antichain.
///
/// The ``ChoiceGraph`` provides the deletion antichain — the maximum set of structurally independent nodes that can be simultaneously deleted. The encoder splits this set in half, tests each half, takes the larger accepted subset, then greedily extends it.
///
/// This is the same algorithm as ``AntichainDeletionEncoder`` but with candidates provided by the graph rather than computed from span caches.
///
/// - Complexity: O(*n* * log *n*) probes where *n* is the antichain size.
public struct GraphDeletionEncoder: GraphEncoder {
    public let name: EncoderName = .graphDeletion

    // MARK: - State

    private var sequence = ChoiceSequence()
    private var candidates: [DeletionCandidate] = []
    private var stack: [StackFrame] = []
    private var greedyPhase: GreedyPhase?
    private var pendingProbeIndices: [Int]?
    private var started = false

    private struct DeletionCandidate {
        let nodeID: Int
        let positionRange: ClosedRange<Int>
    }

    private struct StackFrame {
        let range: Range<Int>
        var stage: FrameStage
        var leftResult: [Int]?
        var rightResult: [Int]?
    }

    private enum FrameStage {
        case testFull
        case awaitFull
        case testLeft
        case awaitLeft
        case testRight
        case awaitRight
        case resolved
    }

    private struct GreedyPhase {
        var best: [Int]
        var candidateIndex: Int
    }

    // MARK: - GraphEncoder

    public mutating func start(
        graph: ChoiceGraph,
        sequence: ChoiceSequence,
        tree: ChoiceTree
    ) {
        self.sequence = sequence
        started = false
        stack = []
        greedyPhase = nil
        pendingProbeIndices = nil

        // Deletion candidates are children of sequence nodes (from the antichain)
        // plus any additional sequence element children not in the antichain.
        // The antichain now correctly excludes zip children and root nodes.
        var candidateSet = Set<Int>()
        let antichainNodeIDs = graph.deletionAntichain
        candidates = antichainNodeIDs.compactMap { nodeID in
            guard let range = graph.nodes[nodeID].positionRange else { return nil }
            candidateSet.insert(nodeID)
            return DeletionCandidate(nodeID: nodeID, positionRange: range)
        }

        // Add sequence element children not already in the antichain.
        // The antichain's greedy construction may miss some elements if they
        // are dependency-related to existing members.
        for node in graph.nodes {
            guard case let .sequence(metadata) = node.kind else { continue }
            guard node.positionRange != nil else { continue }
            let minLength = metadata.lengthConstraint?.lowerBound ?? 0
            guard UInt64(metadata.elementCount) > minLength else { continue }
            for childID in node.children {
                guard candidateSet.contains(childID) == false else { continue }
                let child = graph.nodes[childID]
                guard let childRange = child.positionRange else { continue }
                candidateSet.insert(childID)
                candidates.append(DeletionCandidate(nodeID: childID, positionRange: childRange))
            }
        }

        // Sort by position range size descending (largest first).
        candidates.sort { $0.positionRange.count > $1.positionRange.count }

        guard candidates.isEmpty == false else { return }

        // Initialise the binary split stack with the full candidate set.
        stack.append(StackFrame(
            range: 0 ..< candidates.count,
            stage: .testFull
        ))
    }

    public mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        if started {
            processFeedback(lastAccepted)
        }
        started = true

        // Greedy extension phase.
        if var greedy = greedyPhase {
            while greedy.candidateIndex < candidates.count {
                let index = greedy.candidateIndex
                greedy.candidateIndex += 1
                if greedy.best.contains(index) { continue }
                greedyPhase = greedy

                let testIndices = greedy.best + [index]
                if let probe = buildProbe(deletingIndices: testIndices) {
                    pendingProbeIndices = testIndices
                    return probe
                }
            }
            greedyPhase = nil
            return nil
        }

        // Binary split phase.
        return advanceStack()
    }

    // MARK: - Binary Split

    private mutating func advanceStack() -> ChoiceSequence? {
        while stack.isEmpty == false {
            let frameIndex = stack.count - 1
            switch stack[frameIndex].stage {
            case .testFull:
                let range = stack[frameIndex].range
                let indices = Array(range)
                stack[frameIndex].stage = .awaitFull
                if let probe = buildProbe(deletingIndices: indices) {
                    pendingProbeIndices = indices
                    return probe
                }
                // Empty probe — skip to resolution.
                stack[frameIndex].stage = .resolved

            case .awaitFull:
                // Handled by processFeedback.
                stack[frameIndex].stage = .testLeft

            case .testLeft:
                let range = stack[frameIndex].range
                if range.count <= 1 {
                    stack[frameIndex].stage = .resolved
                    continue
                }
                let mid = range.lowerBound + range.count / 2
                stack.append(StackFrame(range: range.lowerBound ..< mid, stage: .testFull))
                stack[frameIndex].stage = .awaitLeft
                return advanceStack()

            case .awaitLeft:
                stack[frameIndex].stage = .testRight

            case .testRight:
                let range = stack[frameIndex].range
                let mid = range.lowerBound + range.count / 2
                stack.append(StackFrame(range: mid ..< range.upperBound, stage: .testFull))
                stack[frameIndex].stage = .awaitRight
                return advanceStack()

            case .awaitRight:
                // Both halves resolved. Take the larger accepted subset.
                let leftResult = stack[frameIndex].leftResult ?? []
                let rightResult = stack[frameIndex].rightResult ?? []
                let best = leftResult.count >= rightResult.count ? leftResult : rightResult

                stack.removeLast()

                if stack.isEmpty {
                    // Top-level resolution — enter greedy extension.
                    greedyPhase = GreedyPhase(best: best, candidateIndex: 0)
                    return nextProbe(lastAccepted: false)
                }
                // Propagate result to parent.
                let parentIndex = stack.count - 1
                switch stack[parentIndex].stage {
                case .awaitLeft:
                    stack[parentIndex].leftResult = best
                    stack[parentIndex].stage = .testRight
                case .awaitRight:
                    stack[parentIndex].rightResult = best
                    stack[parentIndex].stage = .resolved
                default:
                    break
                }
                continue

            case .resolved:
                let leftResult = stack[frameIndex].leftResult ?? []
                let rightResult = stack[frameIndex].rightResult ?? []
                let best = leftResult.count >= rightResult.count ? leftResult : rightResult

                stack.removeLast()

                if stack.isEmpty {
                    greedyPhase = GreedyPhase(best: best, candidateIndex: 0)
                    return nextProbe(lastAccepted: false)
                }
                let parentIndex = stack.count - 1
                switch stack[parentIndex].stage {
                case .awaitLeft:
                    stack[parentIndex].leftResult = best
                    stack[parentIndex].stage = .testRight
                case .awaitRight:
                    stack[parentIndex].rightResult = best
                    stack[parentIndex].stage = .resolved
                default:
                    break
                }
                continue
            }
        }
        return nil
    }

    // MARK: - Feedback

    private mutating func processFeedback(_ accepted: Bool) {
        if var greedy = greedyPhase {
            if accepted, let indices = pendingProbeIndices {
                greedy.best = indices
            }
            greedyPhase = greedy
            pendingProbeIndices = nil
            return
        }

        guard stack.isEmpty == false else {
            pendingProbeIndices = nil
            return
        }

        let frameIndex = stack.count - 1
        switch stack[frameIndex].stage {
        case .awaitFull:
            if accepted, let indices = pendingProbeIndices {
                // Full set accepted — resolve immediately.
                stack[frameIndex].leftResult = indices
                stack[frameIndex].stage = .resolved
            } else {
                stack[frameIndex].stage = .testLeft
            }
        default:
            break
        }
        pendingProbeIndices = nil
    }

    // MARK: - Candidate Construction

    private func buildProbe(deletingIndices indices: [Int]) -> ChoiceSequence? {
        guard indices.isEmpty == false else { return nil }
        var rangeSet = RangeSet<Int>()
        for index in indices {
            let range = candidates[index].positionRange
            rangeSet.insert(contentsOf: range.lowerBound ..< range.upperBound + 1)
        }
        var candidate = sequence
        candidate.removeSubranges(rangeSet)
        guard candidate.shortLexPrecedes(sequence) else { return nil }
        return candidate
    }
}
