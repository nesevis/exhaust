//
//  ReducerStrategies+SpeculativeDeleteAndRepair.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/2/2026.
//

extension ReducerStrategies {

    /// Pass 5c: Speculative deletion with proportional value repair.
    /// Tries deleting spans AND adjusting remaining values toward their reduction targets
    /// by a uniform delta. This handles cases where deletion alone fails because values encode
    /// positions that become out-of-bounds after deletion.
    ///
    /// Uses divide-and-conquer: tries deleting all spans at a given depth, then recursively
    /// splits into halves on failure. The recursion tree has O(2*n* − 1) nodes, so total
    /// candidates are O(*n*) per depth level.
    ///
    /// - Complexity: O(*D* · *n* · *M*ᵣ) in the worst case, where *D* is the number of distinct
    ///   depths, *n* is the number of spans at a given depth, and *M*ᵣ is the cost of
    ///   `repairAfterDeletion` (see below). Returns on the first successful repair, so amortised
    ///   cost is often much lower.
    static func speculativeDeleteAndRepair<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        spans: [ChoiceSpan]
    ) throws -> (ChoiceSequence, Output)? {
        // Group spans by depth to process each level independently
        var spansByDepth = [Int: [ChoiceSpan]]()
        for span in spans {
            spansByDepth[span.depth, default: []].append(span)
        }

        for depth in spansByDepth.keys.sorted() {
            let depthSpans = spansByDepth[depth]!
            guard !depthSpans.isEmpty else { continue }

            if let result = try divideAndConquerDeleteRepair(
                gen, tree: tree, property: property,
                sequence: sequence, spans: depthSpans[...]
            ) {
                return result
            }
        }
        return nil
    }

    /// Recursively tries deleting the given span slice and repairing. On failure, splits
    /// into halves and recurses on each. The recursion tree has at most 2*n* − 1 nodes.
    private static func divideAndConquerDeleteRepair<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        spans: ArraySlice<ChoiceSpan>
    ) throws -> (ChoiceSequence, Output)? {
        guard !spans.isEmpty else { return nil }

        var shortened = sequence
        shortened.removeSubranges(spans.map(\.range))

        // Only try repair when materialization fails (nil).
        // If materialization succeeds, the values are structurally valid —
        // either the property fails (handled by other passes) or passes
        // (repair can't help since values are already in-range).
        let pureDeletion = try? Interpreters.materialize(gen, with: tree, using: shortened)
        if pureDeletion == nil {
            if let result = try repairAfterDeletion(
                gen, tree: tree, property: property,
                original: sequence, shortened: shortened
            ) {
                return result
            }
        }

        // Base case: single span, nothing more to split
        guard spans.count > 1 else { return nil }

        // Split and recurse on each half
        let mid = spans.startIndex + spans.count / 2
        if let result = try divideAndConquerDeleteRepair(
            gen, tree: tree, property: property,
            sequence: sequence, spans: spans[spans.startIndex..<mid]
        ) {
            return result
        }
        return try divideAndConquerDeleteRepair(
            gen, tree: tree, property: property,
            sequence: sequence, spans: spans[mid..<spans.endIndex]
        )
    }

    /// Given a shortened sequence (after deletion), tries uniform value repair to find
    /// a valid, property-failing configuration.
    ///
    /// - Complexity: O(*s* + log *d* · *M*), where *s* is the shortened sequence length,
    ///   *d* is the maximum bit-pattern distance among remaining values, and *M* is the cost of
    ///   a single oracle call. The coarse sweep makes at most 16 probes, followed by a binary
    ///   search refinement of O(log *d*) probes. Each probe calls `applyUniformRepair` in O(*v*).
    static func repairAfterDeletion<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        original: ChoiceSequence,
        shortened: ChoiceSequence
    ) throws -> (ChoiceSequence, Output)? {
        typealias ValueInfo = (index: Int, bp: UInt64, target: UInt64, distance: UInt64, upward: Bool, value: ChoiceSequenceValue.Value)
        var values = [ValueInfo]()
        for (i, entry) in shortened.enumerated() {
            guard let v = entry.value else { continue }
            let bp = v.choice.bitPattern64
            let target = v.choice.reductionTarget(in: v.validRanges)
            guard bp != target else { continue }
            let upward = target > bp
            let distance = upward ? target - bp : bp - target
            values.append((i, bp, target, distance, upward, v))
        }
        guard !values.isEmpty else { return nil }
        let maxDist = values.map(\.distance).max()!
        guard maxDist > 0 else { return nil }

        // Coarse sweep: ~16 probes from maxDist down to 1
        let sweepStride = max(1, maxDist / 16)
        var bestK: UInt64 = 0
        var bestOutput: Output?

        var k = maxDist
        while k >= 1 {
            let probe = applyUniformRepair(shortened, values: values, k: k)
            if let output = try? Interpreters.materialize(gen, with: tree, using: probe),
               property(output) == false,
               probe.shortLexPrecedes(original) {
                bestK = k
                bestOutput = output
                break
            }
            if k <= sweepStride { break }
            k -= sweepStride
        }

        // If coarse sweep didn't find k but stride > 1, try k=1 as well
        if bestK == 0 && sweepStride > 1 {
            let probe = applyUniformRepair(shortened, values: values, k: 1)
            if let output = try? Interpreters.materialize(gen, with: tree, using: probe),
               property(output) == false,
               probe.shortLexPrecedes(original) {
                bestK = 1
                bestOutput = output
            }
        }

        guard bestK > 0, let foundOutput = bestOutput else { return nil }

        // Refine: binary search between bestK and bestK-sweepStride
        let lowerBound = bestK > sweepStride ? bestK - sweepStride : 1
        if lowerBound < bestK {
            var lo = lowerBound
            var hi = bestK
            var refinedK = bestK
            var refinedOutput = foundOutput
            while lo < hi {
                let mid = lo + (hi - lo) / 2
                let probe = applyUniformRepair(shortened, values: values, k: mid)
                if let output = try? Interpreters.materialize(gen, with: tree, using: probe),
                   property(output) == false,
                   probe.shortLexPrecedes(original) {
                    refinedK = mid
                    refinedOutput = output
                    hi = mid
                } else {
                    lo = mid + 1
                }
            }
            return (applyUniformRepair(shortened, values: values, k: refinedK), refinedOutput)
        }

        return (applyUniformRepair(shortened, values: values, k: bestK), foundOutput)
    }

    /// Applies uniform repair: moves each value min(distance_i, k) toward its reduction target.
    ///
    /// - Complexity: O(*v*), where *v* is the number of values to repair.
    static func applyUniformRepair(
        _ sequence: ChoiceSequence,
        values: [(index: Int, bp: UInt64, target: UInt64, distance: UInt64, upward: Bool, value: ChoiceSequenceValue.Value)],
        k: UInt64
    ) -> ChoiceSequence {
        var result = sequence
        for v in values {
            let delta = min(v.distance, k)
            guard delta > 0 else { continue }
            let newBP = v.upward ? v.bp + delta : v.bp - delta
            let newChoice = ChoiceValue(
                v.value.choice.tag.makeConvertible(bitPattern64: newBP),
                tag: v.value.choice.tag
            )
            result[v.index] = .reduced(.init(choice: newChoice, validRanges: v.value.validRanges))
        }
        return result
    }
}
