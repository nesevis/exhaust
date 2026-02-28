//
//  ReducerStrategies+SimplifyValues.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/2/2026.
//

extension ReducerStrategies {
    /// Pass 3: Try setting values to their semantically simplest form (0 for numbers, "a" for characters).
    /// Uses `find_integer` to batch consecutive simplifications.
    ///
    /// - Complexity: O(*n* · log *n* · *M*), where *n* is the number of simplifiable value spans
    ///   and *M* is the cost of a single oracle call. Each of the up to *n* positions invokes
    ///   `findInteger`, which makes O(log *n*) oracle calls.
    static func simplifyValues<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        valueSpans: [ChoiceSpan],
        rejectCache: inout ReducerCache,
    ) throws -> (ChoiceSequence, Output)? {
        // Filter to spans whose values can actually be simplified
        var valueIndices: [Int] = []
        for span in valueSpans {
            let seqIdx = span.range.lowerBound
            guard case let .value(v) = sequence[seqIdx] else { continue }
            let simplified = v.choice.semanticSimplest
            guard simplified != v.choice, !v.isRangeExplicit || simplified.fits(in: v.validRanges) else { continue }
            valueIndices.append(seqIdx)
        }

        guard !valueIndices.isEmpty else { return nil }

        var current = sequence
        var progress = false
        var latestOutput: Output?

        var i = 0
        while i < valueIndices.count {
            var bestCandidate: ChoiceSequence?
            var bestOutput: Output?
            var bestSize = 0
            let k = AdaptiveProbe.findInteger { (size: Int) in
                guard size > 0 else { return true }
                var candidate = current
                for j in 0 ..< size {
                    let idx = i + j
                    guard idx < valueIndices.count else { return false }
                    let seqIdx = valueIndices[idx]
                    guard case let .value(v) = candidate[seqIdx] else { return false }
                    let simplified = v.choice.semanticSimplest
                    candidate[seqIdx] = .value(.init(choice: simplified, validRanges: v.validRanges, isRangeExplicit: v.isRangeExplicit))
                }
                guard candidate.shortLexPrecedes(current) else {
                    return false
                }
                guard rejectCache.contains(candidate) == false else {
                    return false
                }
                guard let output = try? Interpreters.materialize(gen, with: tree, using: candidate) else {
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
                    latestOutput = bestOutput
                    progress = true
                } else {
                    // Fallback: reconstruct accepted candidate if probe bookkeeping missed it.
                    var candidate = current
                    for j in 0 ..< k {
                        let seqIdx = valueIndices[i + j]
                        guard case let .value(v) = candidate[seqIdx] else { continue }
                        let simplified = v.choice.semanticSimplest
                        candidate[seqIdx] = .value(.init(choice: simplified, validRanges: v.validRanges, isRangeExplicit: v.isRangeExplicit))
                    }
                    if candidate.shortLexPrecedes(current),
                       let output = try? Interpreters.materialize(gen, with: tree, using: candidate),
                       property(output) == false
                    {
                        current = candidate
                        latestOutput = output
                        progress = true
                    }
                }
                i += k
            } else {
                i += 1
            }
        }

        if progress, let output = latestOutput {
            return (current, output)
        }
        return nil
    }
}
