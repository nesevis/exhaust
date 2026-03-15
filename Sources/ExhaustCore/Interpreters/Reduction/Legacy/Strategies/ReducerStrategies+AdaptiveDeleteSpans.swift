//
//  ReducerStrategies+AdaptiveDeleteSpans.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/2/2026.
//

extension ReducerStrategies {
    /// Adaptive span deletion: for each position, finds the largest contiguous batch of same-depth spans that can be deleted while preserving the property failure. Generalizes the contiguous-deletion category from MacIver & Donaldson (ECOOP 2020, §3.1) to tree-structured spans.
    ///
    /// - Complexity: O(*n* · log *n* · *M*), where *n* is the number of spans and *M* is the cost of a single property invocation. Iterates over up to *n* positions; at each, `findInteger` makes
    ///   O(log *n*) property invocations. Returns on first successful deletion.
    static func adaptiveDeleteSpans<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        spans: [ChoiceSpan],
        rejectCache: inout ReducerCache,
        strictness: Interpreters.Strictness = .normal,
        bindIndex _: BindSpanIndex? = nil
    ) throws -> (ChoiceSequence, Output)? {
        var current = sequence

        // Sort spans by depth (outermost first = lowest depth), preserving order within depth
        let sortedSpans = spans

        var i = 0
        while i < sortedSpans.count {
            let span = sortedSpans[i]
            var maxBatch = 0
            while i + maxBatch < sortedSpans.count, sortedSpans[i + maxBatch].depth == span.depth {
                maxBatch += 1
            }
            var bestCandidate: ChoiceSequence?
            var bestOutput: Output?
            var bestSize = 0

            // Use the adaptive probe `findInteger` to find the largest batch we can delete
            let k = AdaptiveProbe.findInteger { (size: Int) in
                guard size > 0 else {
                    return true
                }
                guard size <= maxBatch else {
                    return false
                }

                var rangeSet = RangeSet<Int>()
                for ii in 0 ..< size {
                    rangeSet.insert(contentsOf: sortedSpans[i + ii].range.asRange)
                }

                var candidate = current
                candidate.removeSubranges(rangeSet)

                guard rejectCache.contains(candidate) == false else {
                    return false
                }
                guard let output = try? Interpreters.materialize(gen, with: tree, using: candidate, strictness: strictness) else {
                    rejectCache.insert(candidate)
                    return false
                }
                let fails = property(output) == false
                if fails {
                    if size >= bestSize {
                        bestSize = size
                        bestCandidate = candidate
                        bestOutput = output
                    }
                } else {
                    rejectCache.insert(candidate)
                }
                return fails
            }

            if k > 0 {
                if bestSize == k, let bestCandidate, let bestOutput {
                    current = bestCandidate
                    // Don't advance - try deleting more from the same position
                    // But we need to rebuild spans now that the subranges have been removed
                    return (current, bestOutput)
                }

                // Fallback: reconstruct accepted candidate if probe bookkeeping missed it.
                var rangeSet = RangeSet<Int>()
                for j in 0 ..< k {
                    rangeSet.insert(contentsOf: sortedSpans[i + j].range.asRange)
                }
                var candidate = current
                candidate.removeSubranges(rangeSet)
                if let output = try? Interpreters.materialize(gen, with: tree, using: candidate, strictness: strictness),
                   property(output) == false
                {
                    current = candidate
                    return (current, output)
                }
            }
            i += 1
        }

        return nil
    }
}
