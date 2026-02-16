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
        case slow
        
        var maxStalls: Int {
            switch self {
            case .fast:
                3
            case .slow:
                8
            }
        }
    }
    
    private enum ShrinkPass: String, CaseIterable, Hashable, Equatable, Comparable {
        case naiveSimplifyValuesToSemanticSimplest
        case deleteContainerSpans
        case deleteSequenceBoundaries
        case deleteFreeStandingValues
        case simplifyValuesToSemanticSimplest
        case reduceValuesInTandem
        case reduceValues
        case redistributeNumericPairs
        case normaliseSiblingOrder
        
        static func < (lhs: Interpreters.ShrinkPass, rhs: Interpreters.ShrinkPass) -> Bool {
            (Self.allCases.firstIndex(of: lhs) ?? 0) < (Self.allCases.firstIndex(of: rhs) ?? 0)
        }
    }
    
    public static func reduce<Output>(
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        config: ShrinkConfiguration,
        property: (Output) -> Bool
    ) throws -> (ChoiceSequence, Output)? {
        // Mutable variables
        let isInstrumented: Bool = true
        var currentSequence = ChoiceSequence.flatten(tree)
        // I don't think we need to reflect to regenerate this?
        // There is then a hard dependency on having to have reflectable generators, which is a pain
        let currentTree = tree
        guard var currentOutput = try materialize(gen, with: tree, using: currentSequence) else {
            return nil
        }
        var previousSequence: ChoiceSequence?
        var numberOfImprovements = 0
        var oracleCalls = [ShrinkPass: Int]()
        var stallBudget = config.maxStalls
        var didNaivelyMinimise = false
        var loops = 0
        var passes = ShrinkPass.allCases
        var seen = [ChoiceSequence: Int]()
        while stallBudget > 0 {
            loops += 1
            var didImprove = false
            var nextPasses = [ShrinkPass]()
            if isInstrumented {
                print("Reducer, loop \(loops)")
            }
            for pass in passes {
                // The order of shrink passes to take next turn
                var passImproved = false
                
                let oracle = isInstrumented == false
                    ? property
                    : { v in
                        oracleCalls[pass, default: 0] += 1
                        return property(v)
                    }
                switch pass {
                case .naiveSimplifyValuesToSemanticSimplest:
                    let valueSpans = ChoiceSequence.extractAllValueSpans(from: currentSequence)
                    if didNaivelyMinimise == false, valueSpans.isEmpty == false, let (newSequence, output) = try naiveSimplifyValues(gen, tree: currentTree, property: oracle, sequence: currentSequence, valueSpans: valueSpans) {
                        previousSequence = currentSequence
                        currentSequence = newSequence
                        currentOutput = output
                    }
                    // We only run this once
                    didNaivelyMinimise = true
                case .deleteContainerSpans:
                    // Adaptive container span deletion, ie the […] and (…) spans in [(V)(V)]
                    let containerSpans = ChoiceSequence.extractContainerSpans(from: currentSequence)
                    if containerSpans.isEmpty == false, let (newSequence, output) = try adaptiveDeleteSpans(gen, tree: currentTree, property: oracle, sequence: currentSequence, spans: containerSpans) {
                        previousSequence = currentSequence
                        currentSequence = newSequence
                        currentOutput = output
                        passImproved = true
                    }
                case .deleteSequenceBoundaries:
                    // Pass 2a: Collapse sequence boundaries, i.e [[V][V][V]] -> [[VVV]]
                    let boundarySpans = ChoiceSequence.extractSequenceBoundarySpans(from: currentSequence)
                    if boundarySpans.isEmpty == false, let (newSequence, output) = try adaptiveDeleteSpans(gen, tree: currentTree, property: oracle, sequence: currentSequence, spans: boundarySpans) {
                        previousSequence = currentSequence
                        currentSequence = newSequence
                        currentOutput = output
                        passImproved = true
                    }
                case .deleteFreeStandingValues:
                    // Pass 2b: Sequence element deletion, i.e the individual Vs in [VVVVV]
                    let freeStandingValueSpans = ChoiceSequence.extractFreeStandingValueSpans(from: currentSequence)
                    if freeStandingValueSpans.isEmpty == false, let (newSequence, output) = try adaptiveDeleteSpans(gen, tree: currentTree, property: oracle, sequence: currentSequence, spans: freeStandingValueSpans) {
                        previousSequence = currentSequence
                        currentSequence = newSequence
                        currentOutput = output
                        passImproved = true
                    }
                case .simplifyValuesToSemanticSimplest:
                    let valueSpans = ChoiceSequence.extractAllValueSpans(from: currentSequence)
                    if valueSpans.isEmpty == false, let (newSequence, output) = try simplifyValues(gen, tree: currentTree, property: oracle, sequence: currentSequence, valueSpans: valueSpans) {
                        previousSequence = currentSequence
                        currentSequence = newSequence
                        currentOutput = output
                        passImproved = true
                    }
                case .reduceValues:
                    let valueSpans = ChoiceSequence.extractAllValueSpans(from: currentSequence)
                    if valueSpans.isEmpty == false, let (newSequence, output) = try reduceValues(gen, tree: currentTree, property: oracle, sequence: currentSequence, valueSpans: valueSpans) {
                        previousSequence = currentSequence
                        currentSequence = newSequence
                        currentOutput = output
                        passImproved = true
                    }
                case .redistributeNumericPairs:
                    let valueCount = currentSequence.count(where: { $0.value != nil })
                    if valueCount >= 2, valueCount <= 16,
                       let (newSequence, output) = try redistributeNumericPairs(gen, tree: currentTree, property: oracle, sequence: currentSequence) {
                        previousSequence = currentSequence
                        currentSequence = newSequence
                        currentOutput = output
                        passImproved = true
                    }
                case .reduceValuesInTandem:
                    // Reduce individual values in tandem by equal amounts, via binary search
                    let siblingGroups = ChoiceSequence.extractSiblingGroups(from: currentSequence)
                    if siblingGroups.isEmpty == false, let (newSequence, output) = try reduceValuesInTandem(gen, tree: currentTree, property: oracle, sequence: currentSequence, siblingGroups: siblingGroups) {
                        previousSequence = currentSequence
                        currentSequence = newSequence
                        currentOutput = output
                        passImproved = true
                    }
                case .normaliseSiblingOrder:
                    let siblingGroups = ChoiceSequence.extractSiblingGroups(from: currentSequence)
                    if siblingGroups.isEmpty == false,
                       let (newSequence, output) = try reorderSiblings(gen, tree: currentTree, property: oracle, sequence: currentSequence, siblingGroups: siblingGroups) {
                        previousSequence = currentSequence
                        currentSequence = newSequence
                        currentOutput = output
                        passImproved = true
                    }
                }
                if currentOutput as? [[Int]] == [[-2, -1, 0, 1, 2]] {
                    let bla = currentTree
                }
                if passImproved {
                    print("> \(pass) succeeded \(oracleCalls[pass, default: 0]) \(currentOutput)")
                    didImprove = true
                    nextPasses.insert(pass, at: 0)
                } else {
                    print("x \(pass) failed \(oracleCalls[pass, default: 0])")
                    nextPasses.append(pass)
                }
            }
            passes = nextPasses
            if didImprove, seen[currentSequence, default: 0] < 2 {
                seen[currentSequence, default: 0] += 1
//                print("! improved! \(currentOutput)")
                numberOfImprovements += 1
                stallBudget = config.maxStalls;
                continue
            }
//            print("Pass ended. Improved? \(didImprove) \np:\(previousSequence!.shortString) (\(previousSequence!.hashValue))\nc:\(currentSequence.shortString) (\(currentSequence.hashValue))")

            // No pass improved the sequence — further iterations are deterministic, so stop.
            stallBudget -= 1
        }
        
        if isInstrumented {
            print("Shrinker stalled after \(loops) loops")
            oracleCalls
                .map { ($0.key, $0.value) }
                .sorted(by: { $0.0 < $1.0 })
                .forEach { key, value in
                    print("— \(value):\t\(key)")
                }
            print("\(oracleCalls.values.reduce(0, +)) oracle calls, total")
        }
        
        return (currentSequence, currentOutput)
    }
    
    /// Pass 0: Try setting values to their semantically simplest form
    private static func naiveSimplifyValues<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        valueSpans: [ChoiceSpan]
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
        valueSpans: [ChoiceSpan]
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
                    candidate[seqIdx] = .value(.init(choice: simplified, validRanges: v.validRanges))
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
                    current[seqIdx] = .value(.init(choice: simplified, validRanges: v.validRanges))
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
        valueSpans: [ChoiceSpan]
    ) throws -> (ChoiceSequence, Output)? {
        var current = sequence
        var progress = false
        var latestOutput: Output?

        for span in valueSpans {
            let seqIdx = span.range.lowerBound
            guard let v = current[seqIdx].value else { continue }

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
            } else {
                // No reduction was possible here. Let's try
                // **Local boundary search**: Are there better shrinks just beyond the horizon?
                let offsets = [bestDelta + 1, bestDelta + 2, bestDelta + 4, bestDelta + 8, bestDelta + 16]
                var boundary = current
                for offset in offsets {
                    // Let's make sure we don't under or overflow
                    guard (searchUpward ? UInt64.max - offset >= currentBP : currentBP >= offset) else {
                        continue
                    }
                    let testBP = searchUpward ? currentBP + offset : currentBP - offset
                    let boundaryChoice = ChoiceValue(
                        v.choice.tag.makeConvertible(bitPattern64: testBP),
                        tag: v.choice.tag
                    )
                    guard boundaryChoice.fits(in: v.validRanges) else { continue }
                    boundary[seqIdx] = .value(.init(choice: boundaryChoice, validRanges: v.validRanges))
                    
                    guard boundary.shortLexPrecedes(current) else { continue }
                    
                    if let output = try? materialize(gen, with: tree, using: boundary), property(output) == false {
                        latestOutput = output
                        current = boundary
                        progress = true
                        break
                    }
                }
            }
        }

        if progress, let output = latestOutput {
            return (current, output)
        }
        return nil
    }

    /// Pass 5b: Cross-container value redistribution.
    /// For each pair of numeric values with the same tag, tries to decrease the earlier value
    /// (toward its reduction target) while increasing the later value by the same amount k.
    /// This enables reduction when values in different containers are coupled.
    private static func redistributeNumericPairs<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence
    ) throws -> (ChoiceSequence, Output)? {
        // Collect all numeric value/reduced entries with their sequence indices and container IDs.
        // Container ID increments each time we cross a container boundary (group/sequence close),
        // so values in different containers get different IDs.
        typealias Candidate = (index: Int, value: ChoiceSequenceValue.Value, containerID: Int)
        var candidatesByTag = [TypeTag: [Candidate]]()
        var containerID = 0

        for (i, entry) in sequence.enumerated() {
            switch entry {
            case .group(false), .sequence(false):
                containerID += 1
            case let .value(v), let .reduced(v):
                switch v.choice {
                case .unsigned, .signed, .floating:
                    candidatesByTag[v.choice.tag, default: []].append((i, v, containerID))
                case .character:
                    break
                }
            default:
                break
            }
        }

        var current = sequence
        var progress = false
        var latestOutput: Output?

        for (_, candidates) in candidatesByTag {
            guard candidates.count >= 2 else { continue }

            for ci in 0..<candidates.count {
                for cj in (ci + 1)..<candidates.count {
                    // Only pair values in different containers
                    guard candidates[ci].containerID != candidates[cj].containerID else { continue }

                    let (idx1, _, _) = candidates[ci]
                    let (idx2, _, _) = candidates[cj]

                    // Use current values (may have been updated by prior iterations)
                    guard let fresh1 = current[idx1].value,
                          let fresh2 = current[idx2].value else { continue }

                    let bp1 = fresh1.choice.bitPattern64
                    let target1 = fresh1.choice.reductionTarget(in: fresh1.validRanges)
                    guard bp1 != target1 else { continue }

                    let bp2 = fresh2.choice.bitPattern64
                    let target2 = fresh2.choice.reductionTarget(in: fresh2.validRanges)

                    // Determine direction: move bp1 toward target1
                    let decrease1Upward = target1 > bp1
                    let distance1 = decrease1Upward
                        ? target1 - bp1
                        : bp1 - target1

                    // Compute node2's initial distance from its target
                    let distance2 = bp2 > target2 ? bp2 - target2 : target2 - bp2

                    // Skip if node2 is already at its target — no point moving it away.
                    guard distance2 > 0 else { continue }

                    // Only redistribute when node1 is far enough from its target to justify the
                    // disruption to node2. Small distances are better handled by independent reduction.
                    guard distance1 > 16 else { continue }

                    // Only redistribute if node1 is farther from target than node2.
                    // This prevents degenerate swaps where values just trade magnitudes.
                    guard distance1 > distance2 else { continue }

                    var lastProbe: ChoiceSequence?
                    var lastProbeOutput: Output?

                    let bestK = AdaptiveProbe.findInteger { (k: UInt64) -> Bool in
                        guard k > 0 else { return true }
                        guard k <= distance1 else { return false }

                        // Move node1 toward its target by k
                        let newBP1 = decrease1Upward ? bp1 + k : bp1 - k
                        // Move node2 away from its target by k (opposite direction)
                        let newBP2: UInt64
                        if decrease1Upward {
                            // node1 increases by k, so node2 must decrease by k
                            guard bp2 >= k else { return false }
                            newBP2 = bp2 - k
                        } else {
                            // node1 decreases by k, so node2 must increase by k
                            guard UInt64.max - k >= bp2 else { return false }
                            newBP2 = bp2 + k
                        }

                        let newChoice1 = ChoiceValue(
                            fresh1.choice.tag.makeConvertible(bitPattern64: newBP1),
                            tag: fresh1.choice.tag
                        )
                        let newChoice2 = ChoiceValue(
                            fresh2.choice.tag.makeConvertible(bitPattern64: newBP2),
                            tag: fresh2.choice.tag
                        )

                        guard newChoice1.fits(in: fresh1.validRanges),
                              newChoice2.fits(in: fresh2.validRanges) else { return false }

                        var probe = current
                        probe[idx1] = .reduced(.init(choice: newChoice1, validRanges: fresh1.validRanges))
                        probe[idx2] = .value(.init(choice: newChoice2, validRanges: fresh2.validRanges))

                        guard probe.shortLexPrecedes(current) else { return false }
                        guard let output = try? materialize(gen, with: tree, using: probe) else { return false }
                        let success = property(output) == false
                        if success {
                            lastProbe = probe
                            lastProbeOutput = output
                        }
                        return success
                    }

                    if bestK > 0, let probe = lastProbe, let output = lastProbeOutput {
                        current = probe
                        latestOutput = output
                        progress = true
                    }
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
        siblingGroups: [SiblingGroup]
    ) throws -> (ChoiceSequence, Output)? {
        var current = sequence
        var progress = false
        var latestOutput: Output?
        var liveGroups = siblingGroups

        var groupIndex = 0
        while groupIndex < liveGroups.count {
            let group = liveGroups[groupIndex]
            let ranges = group.ranges
            guard ranges.count >= 2 else {
                groupIndex += 1
                continue
            }

            // Compute comparison keys for each sibling
            let keys = ranges.map { ChoiceSequence.siblingComparisonKey(from: current, range: $0) }

            // Check if already sorted
            let sortedIndices = keys.indices.sorted { lhs, rhs in
                lexicographicallyPrecedes(keys[lhs], keys[rhs])
            }

            if sortedIndices == Array(keys.indices) {
                groupIndex += 1
                continue
            }

            // Build a candidate with siblings in sorted order
            if let (newSeq, output) = try applySiblingPermutation(
                gen, tree: tree, property: property,
                sequence: current, ranges: ranges, permutation: sortedIndices
            ) {
                current = newSeq
                latestOutput = output
                progress = true
                // Re-extract all groups with fresh ranges
                liveGroups = ChoiceSequence.extractSiblingGroups(from: current)
                groupIndex = 0
                continue
            }

            // Full sort failed — bubble sort with live range re-extraction
            var improved = true
            while improved {
                improved = false
                let freshRanges = ChoiceSequence.extractSiblingGroups(from: current)
                    .first(where: { $0.depth == group.depth && $0.ranges.count == ranges.count })?.ranges
                guard let liveRanges = freshRanges else { break }

                for j in 0..<(liveRanges.count - 1) {
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
                        break // Restart bubble pass with fresh ranges
                    }
                }
            }

            // Re-extract for subsequent groups after finishing this one
            liveGroups = ChoiceSequence.extractSiblingGroups(from: current)
            groupIndex += 1
        }

        if progress, let output = latestOutput {
            return (current, output)
        }
        return nil
    }
    
    /// Pass 7: Binary search multiple values toward their reduction target.
    /// For each sibling group of values will test how much it can reduce all siblings by the same amount
    private static func reduceValuesInTandem<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        siblingGroups: [SiblingGroup]
    ) throws -> (ChoiceSequence, Output)? {
        var current = sequence
        var progress = false
        var latestOutput: Output?
        
        for group in siblingGroups {
            // Since all values will be reduced in tandem, grab the distance from semantic zero
            // from the first of the values in this sibling span
            guard
                let firstValueIndex = group.valueRanges.first?.lowerBound,
                case let v = current[firstValueIndex].value, let v else
            {
                continue
            }
            let currentBP = v.choice.bitPattern64
            let targetBP = v.choice.reductionTarget(in: v.validRanges)

            guard currentBP != targetBP else { continue }

            let searchUpward = targetBP > currentBP
            let distance = searchUpward
                ? targetBP - currentBP
                : currentBP - targetBP
            
            guard distance > 1 else { continue }

            var lastProbe: ChoiceSequence?
            var lastProbeOutput: Output?
            let bestDelta = AdaptiveProbe.binarySearchWithGuess(
                { (delta: UInt64) -> Bool in
                    guard delta > 0 else { return true } // predicate(0) assumed true
                    var probe = current
                    for tandemCandidate in group.valueRanges {
                        guard let v = current[tandemCandidate.lowerBound].value else {
                            return true
                        }
                        let newValue = searchUpward
                            ? v.choice.bitPattern64 &+ delta
                            : v.choice.bitPattern64 &- delta
                        let newChoice = ChoiceValue(
                            v.choice.tag.makeConvertible(bitPattern64: newValue),
                            tag: v.choice.tag
                        )
                        guard newChoice.fits(in: v.validRanges) else { continue }
                        probe[tandemCandidate.lowerBound] = .value(.init(choice: newChoice, validRanges: v.validRanges))
                    }
                    
                    guard
                        probe.shortLexPrecedes(current),
                        let output = try? materialize(gen, with: tree, using: probe)
                    else {
                        return false
                    }
                    let success = property(output) == false
                    if success {
                        lastProbeOutput = output
                        lastProbe = probe
                    }
                    return success
                },
                low: UInt64(0),
                high: distance
            )
            
            if let lastProbeOutput, let lastProbe, lastProbe.shortLexPrecedes(current) {
                latestOutput = lastProbeOutput
                current = lastProbe
                progress = true
            }
        }

        if progress, let output = latestOutput {
            return (current, output)
        }
        return nil
    }

    /// Applies a permutation to sibling ranges in a sequence, checks shortlex precedence,
    /// materializes, and tests the property.
    static func applySiblingPermutation<Output>(
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

        // Prepopulate with outer spans
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
        

        // FIXME This is using shortlex, which is where the inconsistency comes in
//        guard candidate.shortLexPrecedes(sequence) else { return nil }
        guard let output = try materialize(gen, with: tree, using: candidate) else { return nil }
        guard property(output) == false else { return nil }

        return (candidate, output)
    }

    /// Lexicographic comparison of two `[ChoiceValue]` arrays.
    private static func lexicographicallyPrecedes(_ lhs: [ChoiceValue], _ rhs: [ChoiceValue]) -> Bool {
        if lhs.count == rhs.count {
        }
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
        spans: [ChoiceSpan]
    ) throws -> (ChoiceSequence, Output)? {
        var current = sequence
        var progress = false
        var latestOutput: Output?

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
