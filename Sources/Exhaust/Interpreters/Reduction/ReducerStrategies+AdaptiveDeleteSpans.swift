//
//  ReducerStrategies+AdaptiveDeleteSpans.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/2/2026.
//

extension ReducerStrategies {
    /// Adaptive span deletion: for each position, finds the largest contiguous batch of same-depth
    /// spans that can be deleted while preserving the property failure.
    ///
    /// - Complexity: O(*n* · log *n* · *M*), where *n* is the number of spans and *M* is the cost
    ///   of a single oracle call. Iterates over up to *n* positions; at each, `findInteger` makes
    ///   O(log *n*) oracle calls. Returns on first successful deletion.
    static func adaptiveDeleteSpans<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        spans: [ChoiceSpan],
        bloomFilter: inout BloomFilter
    ) throws -> (ChoiceSequence, Output)? {
        var current = sequence

        // Sort spans by depth (outermost first = lowest depth), preserving order within depth
        let sortedSpans = spans

        var i = 0
        while i < sortedSpans.count {
            let span = sortedSpans[i]

            // Use the adaptive probe `findInteger` to find the largest batch we can delete
            let k = AdaptiveProbe.findInteger { (size: Int) in
                // Holy shit this entire closure is so expensive!
                var rangesToDelete = [ClosedRange<Int>]()
                var ii = 0
                while ii < size {
                    let index = i + ii

                    guard index < sortedSpans.count else {
                        return false
                    }

                    // Only batch spans at the same depth
                    guard sortedSpans[index].depth == span.depth else {
                        return false
                    }
                    rangesToDelete.append(sortedSpans[index].range)

                    ii += 1
                }

                // Apply deletion
                var candidate = current
                candidate.removeSubranges(rangesToDelete)
                
                guard bloomFilter.contains(candidate) == false else {
                    return false
                }
                guard let output = try? Interpreters.materialize(gen, with: tree, using: candidate) else {
                    bloomFilter.insert(candidate)
                    return false
                }
                let fails = property(output) == false
                if !fails { bloomFilter.insert(candidate) }
                return fails
            }

            if k > 0 {
                // Apply the deletion
                var rangeSet = RangeSet<Int>()
                for j in 0 ..< k {
                    rangeSet.insert(contentsOf: sortedSpans[i + j].range.asRange)
                }

                var candidate = current
                candidate.removeSubranges(rangeSet)

                // Get the output for the accepted candidate
                if let output = try? Interpreters.materialize(gen, with: tree, using: candidate) {
                    current = candidate
                    // Don't advance - try deleting more from the same position
                    // But we need to rebuild spans now that the subranges have been removed
                    return (current, output)
                }
            }
            i += 1
        }

        return nil
    }
}
