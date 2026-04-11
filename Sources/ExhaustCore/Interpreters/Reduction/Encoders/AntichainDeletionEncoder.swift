//
//  AntichainDeletionEncoder.swift
//  Exhaust
//
//  Created by Chris Kolbu on 27/3/2026.
//

import Foundation

/// Delta-debugging over a set of structurally independent deletion candidates to find the maximal jointly-deletable subset.
///
/// Splits the candidate set in half, recurses into both halves via an explicit stack, takes the larger successful subset, then greedily extends it by testing each remaining candidate. Each ``nextProbe(lastAccepted:)`` call emits one deletion candidate and advances the state machine based on acceptance feedback.
///
/// - Complexity: O(*n* · log *n*) probes where *n* is the number of candidates.
public struct AntichainDeletionEncoder: ComposableEncoder {
    public let name: EncoderName = .productSpaceBatch
    public let phase = ReductionPhase.structuralDeletion

    // MARK: - Candidate

    /// A single antichain node's deletion: the spans to remove and their total length.
    public struct Candidate {
        let nodeIndex: Int
        let spans: [ChoiceSpan]
        let deletedLength: Int
    }

    // MARK: - State

    private var sequence = ChoiceSequence()
    private var candidates: [Candidate] = []
    private var stack: [StackFrame] = []
    private var greedyPhase: GreedyPhase?
    private var pendingProbeSpans: [ChoiceSpan]?

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

    // MARK: - ComposableEncoder

    public func estimatedCost(
        sequence _: ChoiceSequence,
        tree _: ChoiceTree,
        positionRange _: ClosedRange<Int>,
        context _: ReductionContext
    ) -> Int? {
        guard candidates.count > 2 else { return nil }
        let count = candidates.count
        let logN = Int(log2(Double(count)).rounded(.up))
        return count * max(1, logN)
    }

    public mutating func start(
        sequence: ChoiceSequence,
        tree _: ChoiceTree,
        positionRange _: ClosedRange<Int>,
        context _: ReductionContext
    ) {
        self.sequence = sequence
        stack = []
        greedyPhase = nil
        pendingProbeSpans = nil

        guard candidates.count > 2 else { return }

        stack.append(StackFrame(
            range: 0 ..< candidates.count,
            stage: .testFull
        ))
    }

    /// Sets the candidates for this encoder. Called by the antichain
    /// composition before ``start(sequence:tree:positionRange:context:)``.
    public mutating func setCandidates(_ newCandidates: [Candidate]) {
        candidates = newCandidates
    }

    public mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        // Process feedback from previous probe.
        if pendingProbeSpans != nil {
            processFeedback(lastAccepted)
            pendingProbeSpans = nil
        }

        // Greedy extension phase.
        if var greedy = greedyPhase {
            let result = advanceGreedy(&greedy)
            greedyPhase = greedy
            return result
        }

        // Binary split phase via explicit stack.
        while stack.isEmpty == false {
            if let probe = advanceStack() {
                return probe
            }
        }

        return nil
    }

    // MARK: - Stack-Based Binary Split

    private mutating func advanceStack() -> ChoiceSequence? {
        guard stack.isEmpty == false else { return nil }
        let frameIndex = stack.count - 1
        let frame = stack[frameIndex]

        switch frame.stage {
        case .testFull:
            let spans = spansForRange(frame.range)
            stack[frameIndex].stage = .awaitFull
            return emitProbe(spans: spans)

        case .awaitFull:
            // Already processed by processFeedback. Should not reach here.
            stack[frameIndex].stage = .testLeft
            return advanceStack()

        case .testLeft:
            let range = frame.range
            if range.count <= 1 {
                // Single element, no split possible. Resolve with no result.
                stack[frameIndex].stage = .resolved
                return advanceStack()
            }
            let mid = range.lowerBound + range.count / 2
            let leftRange = range.lowerBound ..< mid
            // Push left child frame.
            stack.append(StackFrame(range: leftRange, stage: .testFull))
            stack[frameIndex].stage = .awaitLeft
            return advanceStack()

        case .awaitLeft:
            // Left child resolved — its result is in stack[frameIndex].leftResult.
            stack[frameIndex].stage = .testRight
            return advanceStack()

        case .testRight:
            let range = frame.range
            let mid = range.lowerBound + range.count / 2
            let rightRange = mid ..< range.upperBound
            stack.append(StackFrame(range: rightRange, stage: .testFull))
            stack[frameIndex].stage = .awaitRight
            return advanceStack()

        case .awaitRight:
            // Both children resolved. Compare results and enter greedy extension.
            let best: [Int]? = switch (frame.leftResult, frame.rightResult) {
            case let (left?, right?):
                left.count >= right.count ? left : right
            case let (left?, nil):
                left
            case let (nil, right?):
                right
            case (nil, nil):
                nil
            }

            stack.removeLast()

            if let best {
                // Enter greedy extension for this level.
                var greedy = GreedyPhase(
                    best: best,
                    candidateIndex: 0
                )
                // Propagate result up to parent.
                propagateResult(best)
                let result = advanceGreedy(&greedy)
                greedyPhase = greedy
                return result
            }

            // No result from either child. Propagate nil.
            propagateResult(nil)
            return advanceStack()

        case .resolved:
            stack.removeLast()
            return advanceStack()
        }
    }

    private mutating func processFeedback(_ accepted: Bool) {
        // Find which frame this feedback applies to.
        if var greedy = greedyPhase {
            if accepted {
                // Add the last-tested candidate to best.
                let lastIndex = greedy.candidateIndex - 1
                if lastIndex >= 0, lastIndex < candidates.count {
                    greedy.best.append(lastIndex)
                }
            }
            greedyPhase = greedy
            return
        }

        // Binary split feedback.
        guard stack.isEmpty == false else { return }
        let frameIndex = stack.count - 1
        let frame = stack[frameIndex]

        switch frame.stage {
        case .awaitFull:
            if accepted {
                // Full set accepted — resolve immediately with all indices.
                let indices = Array(frame.range)
                stack.removeLast()
                propagateResult(indices)
            } else {
                stack[frameIndex].stage = .testLeft
            }

        case .awaitLeft:
            // A child frame just resolved. The child already called
            // propagateResult which set our leftResult.
            break

        case .awaitRight:
            // A child frame just resolved. The child already called
            // propagateResult which set our rightResult.
            break

        default:
            break
        }
    }

    private mutating func propagateResult(_ result: [Int]?) {
        guard stack.isEmpty == false else { return }
        let parentIndex = stack.count - 1
        let parent = stack[parentIndex]

        switch parent.stage {
        case .awaitLeft:
            stack[parentIndex].leftResult = result
        case .awaitRight:
            stack[parentIndex].rightResult = result
        default:
            break
        }
    }

    // MARK: - Greedy Extension

    private mutating func advanceGreedy(
        _ greedy: inout GreedyPhase
    ) -> ChoiceSequence? {
        let bestSet = Set(greedy.best)

        while greedy.candidateIndex < candidates.count {
            let index = greedy.candidateIndex
            greedy.candidateIndex += 1

            if bestSet.contains(index) { continue }

            // Build candidate: best + this candidate.
            var spans = [ChoiceSpan]()
            for bestIndex in greedy.best {
                spans.append(contentsOf: candidates[bestIndex].spans)
            }
            spans.append(contentsOf: candidates[index].spans)

            return emitProbe(spans: spans)
        }

        // Greedy done — propagate final result up and clear.
        let finalResult = greedy.best
        greedyPhase = nil
        propagateResult(finalResult)
        return advanceStack()
    }

    // MARK: - Probe Construction

    private func spansForRange(_ range: Range<Int>) -> [ChoiceSpan] {
        var spans = [ChoiceSpan]()
        for index in range {
            spans.append(contentsOf: candidates[index].spans)
        }
        return spans
    }

    private mutating func emitProbe(spans: [ChoiceSpan]) -> ChoiceSequence? {
        var rangeSet = RangeSet<Int>()
        for span in spans {
            rangeSet.insert(contentsOf: span.range.asRange)
        }
        var candidate = sequence
        candidate.removeSubranges(rangeSet)
        guard candidate.shortLexPrecedes(sequence) else { return nil }
        pendingProbeSpans = spans
        return candidate
    }
}
