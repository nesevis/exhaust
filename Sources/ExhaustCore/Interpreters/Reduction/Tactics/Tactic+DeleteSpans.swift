//
//  Tactic+DeleteSpans.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/3/2026.
//

/// Adaptively deletes full container spans (groups, sequences, binds).
///
/// Purpose-built deletion tactic: proposes mutations inline, evaluates via
/// ``TacticEvaluation`` for depth-aware single-pass materialization.
/// Uses `.relaxed` strictness so ``GuidedMaterializer`` rebuilds a consistent
/// tree from the mutated sequence — necessary because deleting a container
/// changes the parent's element count.
///
/// Only full spans (starting with an opener marker) are eligible. Content-only
/// spans (inner elements without markers) are excluded because deleting them
/// leaves an empty container that ``GuidedMaterializer`` interprets as
/// zero-length, which is invalid for fixed-length generators.
struct DeleteContainerSpansTactic: ShrinkTactic {
    let name = "deleteContainerSpans"
    let applicability = TacticApplicability.containers

    func apply<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        targetSpans: [ChoiceSpan],
        context: TacticContext,
        property: (Output) -> Bool,
        rejectCache: inout ReducerCache,
    ) throws -> ShrinkResult<Output>? {
        // Filter to full spans only (those starting with an opener marker).
        // Content-only spans start with a value or nested marker — deleting them
        // leaves empty brackets that GuidedMaterializer interprets as zero-length.
        let sortedSpans = targetSpans.filter { span in
            switch sequence[span.range.lowerBound] {
            case .sequence(true, isLengthExplicit: _), .group(true), .bind(true):
                return true
            default:
                return false
            }
        }
        guard sortedSpans.isEmpty == false else { return nil }
        var i = 0
        while i < sortedSpans.count {
            let span = sortedSpans[i]
            var maxBatch = 0
            while i + maxBatch < sortedSpans.count, sortedSpans[i + maxBatch].depth == span.depth {
                maxBatch += 1
            }
            var bestResult: ShrinkResult<Output>?
            var bestSize = 0

            let k = AdaptiveProbe.findInteger { (size: Int) in
                guard size > 0 else { return true }
                guard size <= maxBatch else { return false }

                // ── enc: propose mutation ──
                var rangeSet = RangeSet<Int>()
                for ii in 0 ..< size {
                    rangeSet.insert(contentsOf: sortedSpans[i + ii].range.asRange)
                }
                var candidate = sequence
                candidate.removeSubranges(rangeSet)

                guard candidate.shortLexPrecedes(sequence) else { return false }
                guard rejectCache.contains(candidate) == false else { return false }

                // ── dec: depth-aware evaluation ──
                if let result = try? TacticEvaluation.evaluate(
                    candidate: candidate,
                    gen: gen,
                    tree: tree,
                    context: context,
                    strictness: .relaxed,
                    originalSequence: sequence,
                    property: property
                ) {
                    if size >= bestSize {
                        bestSize = size
                        bestResult = result
                    }
                    return true
                } else {
                    rejectCache.insert(candidate)
                    return false
                }
            }

            if k > 0, let result = bestResult {
                return result
            }
            i += 1
        }
        return nil
    }
}
