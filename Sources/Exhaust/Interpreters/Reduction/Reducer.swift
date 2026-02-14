//
//  Reducer.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation

extension Interpreters {
    
    public enum ShrinkConfiguration {
        case fast
        
        var maxStalls: Int {
            switch self {
            case .fast:
                8
            }
        }
    }
    
    public static func reduce<Output>(
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        config: ShrinkConfiguration,
        property: (Output) -> Bool
    ) throws -> (ChoiceSequence, Output)? {
        // Mutable variables
        var currentSequence = ChoiceSequence.flatten(tree)
        // I don't think we need to reflect to regenerate this?
        // There is then a hard dependency on having to have reflectable generators, which is a pain
        let currentTree = tree
        guard var currentOutput = try materialize(gen, with: tree, using: currentSequence) else {
            return nil
        }
        var stallBudget = config.maxStalls
        var didNaivelyMinimise = false
        
        while stallBudget > 0 {
            var didImprove = false

            let valueSpans = ChoiceSequence.extractAllValueSpans(from: currentSequence)
            if didNaivelyMinimise == false, valueSpans.isEmpty == false, let (newSequence, output) = try naiveSimplifyValues(gen, tree: currentTree, property: property, sequence: currentSequence, valueSpans: valueSpans) {
                currentSequence = newSequence
                currentOutput = output
                didNaivelyMinimise = true // TODO: Run this once only, or try it every run?
            }
            
            let containerSpans = ChoiceSequence.extractContainerSpans(from: currentSequence)
            // Pass 1: Adaptive container span deletion, ie the […] and (…) spans in [(V)(V)]
            if containerSpans.isEmpty == false, let (newSequence, output) = try adaptiveDeleteSpans(gen, tree: currentTree, property: property, sequence: currentSequence, spans: containerSpans) {
                currentSequence = newSequence
                currentOutput = output
                didImprove = true
                // TODO: Continue to next pass, do not return from here
            }

            if didImprove { stallBudget = config.maxStalls; continue }

            // Pass 2a: Collapse sequence boundaries, i.e [[V][V][V]] -> [[VVV]]
            let boundarySpans = ChoiceSequence.extractSequenceBoundarySpans(from: currentSequence)
            if boundarySpans.isEmpty == false, let (newSequence, output) = try adaptiveDeleteSpans(gen, tree: currentTree, property: property, sequence: currentSequence, spans: boundarySpans) {
                currentSequence = newSequence
                currentOutput = output
                didImprove = true
                // TODO: Continue to next pass, do not return from here
            }

            if didImprove { stallBudget = config.maxStalls; continue }

            // Pass 2b: Sequence element deletion, i.e the individual Vs in [VVVVV]
            let freeStandingValueSpans = ChoiceSequence.extractFreeStandingValueSpans(from: currentSequence)
            if freeStandingValueSpans.isEmpty == false, let (newSequence, output) = try adaptiveDeleteSpans(gen, tree: currentTree, property: property, sequence: currentSequence, spans: freeStandingValueSpans) {
                currentSequence = newSequence
                currentOutput = output
                didImprove = true
                // TODO: Continue to next pass, do not return from here
            }

            if didImprove { stallBudget = config.maxStalls; continue }

            // Pass 3: Simplify values to semantic simplest
            if valueSpans.isEmpty == false, let (newSequence, output) = try simplifyValues(gen, tree: currentTree, property: property, sequence: currentSequence, valueSpans: valueSpans) {
                currentSequence = newSequence
                currentOutput = output
                didImprove = true
            }

            if didImprove { stallBudget = config.maxStalls; continue }
            
            // Pass 5: Reduce individual values via binary search toward their reduction target
            if valueSpans.isEmpty == false, let (newSequence, output) = try reduceValues(gen, tree: currentTree, property: property, sequence: currentSequence, valueSpans: valueSpans) {
                currentSequence = newSequence
                currentOutput = output
                didImprove = true
            }

            if didImprove { stallBudget = config.maxStalls; continue }

            // Pass 6: Reorder siblings for normalization
            let siblingGroups = ChoiceSequence.extractSiblingGroups(from: currentSequence)
            if siblingGroups.isEmpty == false,
               let (newSequence, output) = try reorderSiblings(gen, tree: currentTree, property: property, sequence: currentSequence, siblingGroups: siblingGroups) {
                currentSequence = newSequence
                currentOutput = output
                didImprove = true
            }

            if didImprove { stallBudget = config.maxStalls; continue }

            // No pass improved the sequence — further iterations are deterministic, so stop.
            break
        }
        
        return (currentSequence, currentOutput)
    }
    
    /// Pass 0: Try setting values to their semantically simplest form
    private static func naiveSimplifyValues<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        valueSpans: [ChoiceSequence.ChoiceSpan]
    ) throws -> (ChoiceSequence, Output)? {
        var updatedSequence = sequence
        for span in valueSpans {
            let seqIdx = span.range.lowerBound
            guard case let .value(v) = sequence[seqIdx] else { continue }
            let simplified = v.choice.semanticSimplest
            guard simplified != v.choice, simplified.fits(in: v.validRanges) else { continue }
            updatedSequence[seqIdx] = .value(.init(choice: simplified, validRanges: v.validRanges))
        }
        guard updatedSequence != sequence else {
            return nil
        }
        if let output = try? materialize(gen, with: tree, using: updatedSequence), property(output) == false {
            return (updatedSequence, output)
        }
        return nil
    }
    
    /// Pass 3: Try setting values to their semantically simplest form (0 for numbers, "a" for characters).
    /// Uses `find_integer` to batch consecutive simplifications.
    private static func simplifyValues<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        valueSpans: [ChoiceSequence.ChoiceSpan]
    ) throws -> (ChoiceSequence, Output)? {
        // Filter to spans whose values can actually be simplified
        var valueIndices: [Int] = []
        for span in valueSpans {
            let seqIdx = span.range.lowerBound
            guard case let .value(v) = sequence[seqIdx] else { continue }
            let simplified = v.choice.semanticSimplest
            guard simplified != v.choice, simplified.fits(in: v.validRanges) else { continue }
            valueIndices.append(seqIdx)
        }

        guard !valueIndices.isEmpty else { return nil }

        var current = sequence
        var progress = false
        var latestOutput: Output?

        var i = 0
        while i < valueIndices.count {
            let k = AdaptiveProbe.findInteger { (size: Int) in
                var candidate = current
                for j in 0..<size {
                    let idx = i + j
                    guard idx < valueIndices.count else { return false }
                    let seqIdx = valueIndices[idx]
                    guard case let .value(v) = candidate[seqIdx] else { return false }
                    let simplified = v.choice.semanticSimplest
                    candidate[seqIdx] = .reduced(.init(choice: simplified, validRanges: v.validRanges))
                }
                guard candidate.shortLexPrecedes(current) else {
                    return false
                }
                do {
                    guard let output = try materialize(gen, with: tree, using: candidate) else {
                        return false
                    }
                    return property(output) == false
                } catch {
                    return false
                }
            }

            if k > 0 {
                for j in 0..<k {
                    let seqIdx = valueIndices[i + j]
                    guard case let .value(v) = current[seqIdx] else { continue }
                    let simplified = v.choice.semanticSimplest
                    current[seqIdx] = .reduced(.init(choice: simplified, validRanges: v.validRanges))
                }
                if let output = try? materialize(gen, with: tree, using: current) {
                    latestOutput = output
                    progress = true
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

    /// Pass 5: Binary search each individual value toward its reduction target.
    /// For each `.value` entry, computes the ideal target (semantic simplest clamped to valid ranges),
    /// then binary searches between the current bit pattern and the target to find the minimum failing value.
    private static func reduceValues<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        valueSpans: [ChoiceSequence.ChoiceSpan]
    ) throws -> (ChoiceSequence, Output)? {
        var current = sequence
        var progress = false
        var latestOutput: Output?

        for span in valueSpans {
            let seqIdx = span.range.lowerBound
            guard case let .value(v) = current[seqIdx] else { continue }

            let currentBP = v.choice.bitPattern64
            let targetBP = v.choice.reductionTarget(in: v.validRanges)

            guard currentBP != targetBP else { continue }

            let searchUpward = targetBP > currentBP
            let distance = searchUpward
                ? targetBP - currentBP
                : currentBP - targetBP

            // Try target directly
            let targetChoice = ChoiceValue(
                v.choice.tag.makeConvertible(bitPattern64: targetBP),
                tag: v.choice.tag
            )
            var candidate = current
            candidate[seqIdx] = .reduced(.init(choice: targetChoice, validRanges: v.validRanges))
            if candidate.shortLexPrecedes(current),
               let output = try? materialize(gen, with: tree, using: candidate),
               property(output) == false {
                current = candidate
                latestOutput = output
                progress = true
                continue
            }

            // Binary search: predicate(delta) means "can we move delta steps toward the target and still fail?"
            // predicate(0) = true (no change), predicate(distance) = false (target was just rejected)
            guard distance > 1 else { continue }

            // Compute a guess: midpoint of the containing valid range, converted to delta space
            let guess: UInt64? = {
                guard let containingRange = v.validRanges.first(where: { $0.contains(currentBP) }) else {
                    return nil
                }
                let rangeMid = containingRange.lowerBound / 2 + containingRange.upperBound / 2
                let guessDelta: UInt64
                if searchUpward {
                    guessDelta = rangeMid > currentBP ? rangeMid - currentBP : 0
                } else {
                    guessDelta = currentBP > rangeMid ? currentBP - rangeMid : 0
                }
                // Clamp to valid delta range [0, distance)
                guard guessDelta > 0 && guessDelta < distance else { return nil }
                return guessDelta
            }()

            let bestDelta = AdaptiveProbe.binarySearchWithGuess(
                { (delta: UInt64) -> Bool in
                    guard delta > 0 else { return true } // predicate(0) assumed true
                    let newBP = searchUpward ? currentBP + delta : currentBP - delta
                    let newChoice = ChoiceValue(
                        v.choice.tag.makeConvertible(bitPattern64: newBP),
                        tag: v.choice.tag
                    )
                    guard newChoice.fits(in: v.validRanges) else { return false }
                    var probe = current
                    probe[seqIdx] = .reduced(.init(choice: newChoice, validRanges: v.validRanges))
                    guard probe.shortLexPrecedes(current) else { return false }
                    guard let output = try? materialize(gen, with: tree, using: probe) else { return false }
                    return property(output) == false
                },
                low: UInt64(0),
                high: distance,
                guess: guess
            )

            if bestDelta > 0 {
                let newBP = searchUpward ? currentBP + bestDelta : currentBP - bestDelta
                let newChoice = ChoiceValue(
                    v.choice.tag.makeConvertible(bitPattern64: newBP),
                    tag: v.choice.tag
                )
                current[seqIdx] = .reduced(.init(choice: newChoice, validRanges: v.validRanges))
                if let output = try? materialize(gen, with: tree, using: current) {
                    latestOutput = output
                    progress = true
                }
            }
        }

        if progress, let output = latestOutput {
            return (current, output)
        }
        return nil
    }

    /// Pass 6: Reorder sibling elements within containers to produce normalized output.
    /// For each sibling group, tries sorting all siblings by their comparison keys.
    /// Falls back to adjacent swaps (bubble-sort style) if the full sort is rejected.
    private static func reorderSiblings<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        siblingGroups: [ChoiceSequence.SiblingGroup]
    ) throws -> (ChoiceSequence, Output)? {
        var current = sequence
        var progress = false
        var latestOutput: Output?

        for group in siblingGroups {
            let ranges = group.ranges
            guard ranges.count >= 2 else { continue }

            // Compute comparison keys for each sibling
            let keys = ranges.map { ChoiceSequence.siblingComparisonKey(from: current, range: $0) }

            // Check if already sorted
            let sortedIndices = keys.indices.sorted { lhs, rhs in
                lexicographicallyPrecedes(keys[lhs], keys[rhs])
            }

            if sortedIndices == Array(keys.indices) {
                continue // Already sorted
            }

            // Build a candidate with siblings in sorted order
            if let (newSeq, output) = try applySiblingPermutation(
                gen, tree: tree, property: property,
                sequence: current, ranges: ranges, permutation: sortedIndices
            ) {
                current = newSeq
                latestOutput = output
                progress = true
                continue
            }

            // Full sort failed — try adjacent swaps (bubble sort style)
            var improved = true
            while improved {
                improved = false
                for j in 0..<(ranges.count - 1) {
                    let currentRanges = ChoiceSequence.extractSiblingGroups(from: current)
                        .first(where: { $0.depth == group.depth && $0.ranges.count == ranges.count })?.ranges
                    guard let liveRanges = currentRanges, j + 1 < liveRanges.count else { break }

                    let keyA = ChoiceSequence.siblingComparisonKey(from: current, range: liveRanges[j])
                    let keyB = ChoiceSequence.siblingComparisonKey(from: current, range: liveRanges[j + 1])

                    guard !lexicographicallyPrecedes(keyA, keyB) && keyA != keyB else { continue }

                    // Swap j and j+1
                    var swapPerm = Array(0..<liveRanges.count)
                    swapPerm.swapAt(j, j + 1)

                    if let (newSeq, output) = try applySiblingPermutation(
                        gen, tree: tree, property: property,
                        sequence: current, ranges: liveRanges, permutation: swapPerm
                    ) {
                        current = newSeq
                        latestOutput = output
                        progress = true
                        improved = true
                    }
                }
            }
        }

        if progress, let output = latestOutput {
            return (current, output)
        }
        return nil
    }

    /// Applies a permutation to sibling ranges in a sequence, checks shortlex precedence,
    /// materializes, and tests the property.
    private static func applySiblingPermutation<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        ranges: [ClosedRange<Int>],
        permutation: [Int]
    ) throws -> (ChoiceSequence, Output)? {
        // Extract the slices in original order
        let slices = ranges.map { Array(sequence[$0]) }

        // Build candidate by reconstructing: prefix + permuted siblings interleaved + suffix
        // Since siblings are contiguous within their parent container, we can replace the
        // entire span from first range start to last range end.
        let spanStart = ranges.first!.lowerBound
        let spanEnd = ranges.last!.upperBound

        var candidate = Array(sequence[..<spanStart])
        for i in ranges.indices {
            // If there's a gap between previous range end and current range start, include it
            if i > 0 {
                let gapStart = ranges[i - 1].upperBound + 1
                let gapEnd = ranges[i].lowerBound
                if gapStart < gapEnd {
                    candidate.append(contentsOf: sequence[gapStart..<gapEnd])
                }
            }
            candidate.append(contentsOf: slices[permutation[i]])
        }
        if spanEnd + 1 < sequence.count {
            candidate.append(contentsOf: sequence[(spanEnd + 1)...])
        }

        guard candidate.shortLexPrecedes(sequence) else { return nil }
        guard let output = try materialize(gen, with: tree, using: candidate) else { return nil }
        guard property(output) == false else { return nil }

        return (candidate, output)
    }

    /// Lexicographic comparison of two `[ChoiceValue]` arrays.
    private static func lexicographicallyPrecedes(_ lhs: [ChoiceValue], _ rhs: [ChoiceValue]) -> Bool {
        for (a, b) in zip(lhs, rhs) {
            if a < b { return true }
            if b < a { return false }
        }
        return lhs.count < rhs.count
    }

    private static func adaptiveDeleteSpans<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        spans: [ChoiceSequence.ChoiceSpan]
    ) throws -> (ChoiceSequence, Output)? {
        var current = sequence
        var progress = false
        var latestOutput: Output?

        // Sort spans by depth (outermost first = lowest depth), preserving order within depth
        let sortedSpans = spans.sorted { $0.depth < $1.depth }

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
                if candidate.shortLexPrecedes(current) {
                    do {
                        guard let output = try materialize(gen, with: tree, using: candidate) else {
                            return false
                        }
                        return property(output) == false
                    } catch {
                        return false
                    }
                }
                return false
            }

            if k > 0 {
                // Apply the deletion
                var rangeSet = RangeSet<Int>()
                for j in 0..<k {
                    rangeSet.insert(contentsOf: sortedSpans[i + j].range.asRange)
                }

                var candidate = current
                candidate.removeSubranges(rangeSet)

                // Get the output for the accepted candidate
                if let output = try? materialize(gen, with: tree, using: candidate) {
                    current = candidate
                    latestOutput = output
                    progress = true
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
