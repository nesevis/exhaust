//
//  Tactic+DeleteFreeStandingValues.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/3/2026.
//

/// Adaptively deletes free-standing value spans (bare values not inside container groups).
///
/// Purpose-built deletion tactic: proposes mutations inline, evaluates via
/// ``TacticEvaluation`` for depth-aware single-pass materialization.
/// Strictness is `.relaxed` because removal shifts entries out of alignment with tree positions.
struct DeleteFreeStandingValuesTactic: ShrinkTactic {
    let name = "deleteFreeStandingValues"
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
        let sortedSpans = targetSpans
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
