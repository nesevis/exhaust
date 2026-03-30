//
//  AdaptiveDeletionEncoder.swift
//  Exhaust
//
//  Created by Chris Kolbu on 14/3/2026.
//

/// Shared adaptive batch-deletion logic for all deletion encoders.
///
/// Uses ``FindIntegerStepper`` to binary-search for the largest contiguous batch of same-depth spans
/// that can be deleted. Each concrete deletion encoder provides target filtering; this struct drives
/// the probe loop.
///
/// For each batch size the stepper suggests, candidates are tried from both ends of the depth group:
/// first tail-anchored (deleting the last spans), then head-anchored (deleting the first spans).
/// This ensures that useful content at either end of a sequence is preserved. For example, in a
/// 2-element array `[empty, important]`, head-anchored deletion removes the empty element while
/// tail-anchored deletion would remove the important one.
struct AdaptiveDeletionEncoder {
    // MARK: - State

    private var sequence = ChoiceSequence()
    private var sortedSpans: [ChoiceSpan] = []
    private var spanIndex = 0
    private var maxBatch = 0
    private var stepper = FindIntegerStepper()
    private var needsNewGroup = true
    private var didEmitCandidate = false

    /// When true, a tail-anchored candidate was emitted for `currentBatchSize`
    /// and we should try the head anchor before advancing the stepper.
    private var pendingHeadRetry = false

    /// The batch size currently being probed (retained across the tail/head alternation).
    private var currentBatchSize = 0

    /// Whether the stepper's best accepted result came from a tail-anchored deletion.
    /// Determines ``spanIndex`` advancement after the stepper converges: head-accepted
    /// advances past the deleted head spans, tail-accepted skips the entire depth group.
    private var bestAcceptedFromTail = false

    // MARK: - Anchor

    private enum DeletionAnchor { case head, tail }

    // MARK: - API

    /// Initializes the encoder with target spans (already filtered by the caller).
    mutating func start(sequence: ChoiceSequence, sortedSpans: [ChoiceSpan]) {
        self.sequence = sequence
        self.sortedSpans = sortedSpans
        spanIndex = 0
        needsNewGroup = true
        didEmitCandidate = false
        pendingHeadRetry = false
        currentBatchSize = 0
        bestAcceptedFromTail = false
    }

    /// Produces the next deletion candidate, or `nil` when all groups are exhausted.
    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        while spanIndex < sortedSpans.count {
            // A tail candidate was emitted last time. Process its feedback
            // and try the head anchor if the tail was rejected.
            if pendingHeadRetry {
                if let candidate = handlePendingHeadRetry(lastAccepted: lastAccepted) {
                    return candidate
                }
                continue
            }

            if needsNewGroup {
                maxBatch = 0
                let depth = sortedSpans[spanIndex].depth
                var j = spanIndex
                while j < sortedSpans.count, sortedSpans[j].depth == depth {
                    maxBatch += 1
                    j += 1
                }
                currentBatchSize = stepper.start()
                needsNewGroup = false
                didEmitCandidate = false
                bestAcceptedFromTail = false
                if let candidate = emitForBatchSize(currentBatchSize) {
                    return candidate
                }
                // Neither anchor produced a candidate. Fall through to stepper
                // advance on the next iteration (didEmitCandidate is false, so
                // the stepper receives a rejection).
                continue
            }

            // Use actual lastAccepted only if we emitted a candidate last time.
            // When buildCandidate returned nil, no probe was emitted,
            // so lastAccepted is stale — treat as rejection.
            let feedback = didEmitCandidate ? lastAccepted : false
            didEmitCandidate = false
            if feedback {
                // A head candidate was accepted (tail feedback is handled in
                // pendingHeadRetry above, so we only reach here for head).
                bestAcceptedFromTail = false
            }
            if let nextSize = stepper.advance(lastAccepted: feedback) {
                currentBatchSize = nextSize
                if let candidate = emitForBatchSize(nextSize) {
                    return candidate
                }
                continue
            }

            advancePastGroup()
        }
        return nil
    }

    // MARK: - Tail/Head Alternation

    /// Processes feedback for a tail-anchored candidate and tries head if tail was rejected.
    ///
    /// Returns the next candidate to emit, or nil if the stepper should be advanced
    /// (the caller's while loop continues).
    private mutating func handlePendingHeadRetry(lastAccepted: Bool) -> ChoiceSequence? {
        pendingHeadRetry = false
        let tailFeedback = didEmitCandidate ? lastAccepted : false
        didEmitCandidate = false

        if tailFeedback {
            // Tail was accepted. Record anchor and advance the stepper.
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

        // Head also produced no candidate. Advance stepper with rejection.
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

    /// Tries to emit a candidate for the given batch size: tail-anchored first
    /// (for sub-maximal batches), then head-anchored.
    ///
    /// When a tail candidate is emitted, ``pendingHeadRetry`` is set so the
    /// head anchor is tried if the tail is rejected.
    private mutating func emitForBatchSize(_ batchSize: Int) -> ChoiceSequence? {
        // For sub-maximal batches, try tail first. When batchSize == maxBatch,
        // tail and head select the same spans — skip the duplicate.
        if batchSize < maxBatch {
            if let candidate = buildCandidate(batchSize: batchSize, anchor: .tail) {
                pendingHeadRetry = true
                didEmitCandidate = true
                return candidate
            }
        }
        // Full batch, or tail produced no candidate — try head.
        if let candidate = buildCandidate(batchSize: batchSize, anchor: .head) {
            didEmitCandidate = true
            return candidate
        }
        return nil
    }

    /// Advances ``spanIndex`` past the current depth group after the stepper converges.
    private mutating func advancePastGroup() {
        let accepted = stepper.bestAccepted
        if accepted > 0 {
            // Head-accepted: skip past the deleted head spans; remaining tail
            // spans form a new group. Tail-accepted: the deleted spans were at
            // the end, so remaining head spans have stale positions — skip the
            // entire group.
            spanIndex += bestAcceptedFromTail ? maxBatch : accepted
        } else {
            spanIndex += 1
        }
        needsNewGroup = true
        pendingHeadRetry = false
    }

    // MARK: - Candidate Construction

    private func buildCandidate(batchSize: Int, anchor: DeletionAnchor) -> ChoiceSequence? {
        guard batchSize > 0, batchSize <= maxBatch else { return nil }
        let startOffset = switch anchor {
        case .head: 0
        case .tail: maxBatch - batchSize
        }
        var rangeSet = RangeSet<Int>()
        var ii = 0
        while ii < batchSize {
            rangeSet.insert(contentsOf: sortedSpans[spanIndex + startOffset + ii].range.asRange)
            ii += 1
        }
        var candidate = sequence
        candidate.removeSubranges(rangeSet)
        guard candidate.shortLexPrecedes(sequence) else { return nil }
        return candidate
    }
}
