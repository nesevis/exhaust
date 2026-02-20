//
//  ReducerStrategies+DeleteAlignedSiblingWindows.swift
//  Exhaust
//
//  Created by Chris Kolbu on 19/2/2026.
//

extension ReducerStrategies {
    private struct AlignedDeletionSlot {
        let ranges: [ClosedRange<Int>]
    }

    private struct AlignedContainerChild {
        let range: ClosedRange<Int>
        let kind: SiblingChildKind
        let valueTag: TypeTag?
    }

    private struct AlignedContainerDescriptor {
        let depth: Int
        let range: ClosedRange<Int>
        let children: [AlignedContainerChild]
    }

    /// Coordinated deletion across structurally aligned sibling containers.
    /// Builds cohorts of sibling container pairs and deletes aligned child windows.
    /// Alignment is index-based over the shared prefix (`0..<min(childCountA, childCountB)`),
    /// so containers do not need identical child counts.
    ///
    /// - Complexity: O(*g* · *c* · *n* · log *n* · *M*), where *g* is sibling group count, *c* is
    ///   cohorts per group, *n* is child count per cohort, and *M* is one oracle call.
    static func deleteAlignedSiblingWindows<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        siblingGroups: [SiblingGroup],
        rejectCache: inout ReducerCache,
    ) throws -> (ChoiceSequence, Output)? {
        let cohorts = alignedContainerCohorts(in: sequence)
            + alignedSiblingGroupCohorts(from: siblingGroups)
            + rootSequenceContainerCohorts(in: sequence)
        for slots in cohorts where !slots.isEmpty {
            var slotStart = 0
            while slotStart < slots.count {
                let maxBatch = slots.count - slotStart
                var bestCandidate: ChoiceSequence?
                var bestOutput: Output?
                var bestSize = 0

                let k = AdaptiveProbe.findInteger { (size: Int) -> Bool in
                    guard size > 0 else { return true }
                    guard size <= maxBatch else { return false }

                    var rangeSet = RangeSet<Int>()
                    for offset in 0 ..< size {
                        for range in slots[slotStart + offset].ranges {
                            rangeSet.insert(contentsOf: range.asRange)
                        }
                    }

                    var candidate = sequence
                    candidate.removeSubranges(rangeSet)

                    guard candidate.shortLexPrecedes(sequence) else { return false }
                    guard rejectCache.contains(candidate) == false else { return false }
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
                        return (bestCandidate, bestOutput)
                    }

                    var rangeSet = RangeSet<Int>()
                    for offset in 0 ..< k {
                        for range in slots[slotStart + offset].ranges {
                            rangeSet.insert(contentsOf: range.asRange)
                        }
                    }
                    var candidate = sequence
                    candidate.removeSubranges(rangeSet)

                    if candidate.shortLexPrecedes(sequence),
                       rejectCache.contains(candidate) == false,
                       let output = try? Interpreters.materialize(gen, with: tree, using: candidate),
                       property(output) == false
                    {
                        return (candidate, output)
                    }
                    rejectCache.insert(candidate)
                }

                if k == 0, maxBatch >= 2 {
                    // Non-monotonic fallback: coupled failures may reject size=1 but accept size=2+.
                    // Probe larger batches directly to avoid getting stuck on monotonic assumptions.
                    var probeSizes = [2, 3, 4, maxBatch]
                    probeSizes = Array(Set(probeSizes))
                        .filter { $0 > 1 && $0 <= maxBatch }
                        .sorted()

                    var bestNonMonotoneCandidate: ChoiceSequence?
                    var bestNonMonotoneOutput: Output?
                    var bestNonMonotoneSize = 0

                    for size in probeSizes {
                        var rangeSet = RangeSet<Int>()
                        for offset in 0 ..< size {
                            for range in slots[slotStart + offset].ranges {
                                rangeSet.insert(contentsOf: range.asRange)
                            }
                        }

                        var candidate = sequence
                        candidate.removeSubranges(rangeSet)
                        guard candidate.shortLexPrecedes(sequence) else { continue }
                        guard rejectCache.contains(candidate) == false else { continue }
                        guard let output = try? Interpreters.materialize(gen, with: tree, using: candidate) else {
                            rejectCache.insert(candidate)
                            continue
                        }
                        if property(output) == false {
                            if size >= bestNonMonotoneSize {
                                bestNonMonotoneSize = size
                                bestNonMonotoneCandidate = candidate
                                bestNonMonotoneOutput = output
                            }
                        } else {
                            rejectCache.insert(candidate)
                        }
                    }

                    if let bestNonMonotoneCandidate, let bestNonMonotoneOutput {
                        return (bestNonMonotoneCandidate, bestNonMonotoneOutput)
                    }
                }
                slotStart += 1
            }

            // Bounded non-contiguous fallback for coupled cases where contiguous windows fail.
            if let (candidate, output) = try bestSubsetDeletionCandidate(
                gen,
                tree: tree,
                property: property,
                sequence: sequence,
                slots: slots,
                rejectCache: &rejectCache,
            ) {
                return (candidate, output)
            }
        }

        return nil
    }

    private static func alignedSiblingGroupCohorts(
        from siblingGroups: [SiblingGroup],
    ) -> [[AlignedDeletionSlot]] {
        var cohorts = [[AlignedDeletionSlot]]()
        for group in siblingGroups where group.ranges.count >= 2 {
            // Focus this pass on coordinated container deletions to avoid overlapping
            // behavior with single-value deletion passes.
            guard group.kind != .bareValue else { continue }
            cohorts.append(group.ranges.map { AlignedDeletionSlot(ranges: [$0]) })
        }
        return cohorts
    }

    private static func rootSequenceContainerCohorts(
        in sequence: ChoiceSequence,
    ) -> [[AlignedDeletionSlot]] {
        let sequenceContainerSpans = ChoiceSequence.extractContainerSpans(from: sequence).filter { span in
            guard span.kind == .sequence(true) else { return false }
            guard span.range.lowerBound >= 0, span.range.upperBound < sequence.count else { return false }
            return sequence[span.range.lowerBound] == .sequence(true)
                && sequence[span.range.upperBound] == .sequence(false)
        }
        guard sequenceContainerSpans.count >= 2 else { return [] }
        guard let minDepth = sequenceContainerSpans.map(\.depth).min() else { return [] }

        let rootLevel = sequenceContainerSpans
            .filter { $0.depth == minDepth }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
        guard rootLevel.count >= 2 else { return [] }

        // For fixed-arity tuples/zips, deleting whole sequence containers can invalidate structure.
        // Delete each list's content span instead, preserving the list container itself.
        let contentSlots = rootLevel.compactMap { span -> AlignedDeletionSlot? in
            let lower = span.range.lowerBound + 1
            let upper = span.range.upperBound - 1
            guard lower <= upper else { return nil } // already-empty list
            return AlignedDeletionSlot(ranges: [lower ... upper])
        }
        guard contentSlots.count >= 2 else { return [] }

        return [contentSlots]
    }

    private static func bestSubsetDeletionCandidate<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        slots: [AlignedDeletionSlot],
        rejectCache: inout ReducerCache,
    ) throws -> (ChoiceSequence, Output)? {
        // Keep combinatorics bounded.
        guard slots.count >= 2, slots.count <= 10 else { return nil }

        var bestCandidate: ChoiceSequence?
        var bestOutput: Output?
        var bestDeletionCount = 0

        let totalMasks = 1 << slots.count
        // Iterate larger subsets first to bias toward stronger deletions.
        for deletionCount in stride(from: slots.count, through: 2, by: -1) {
            for mask in 1 ..< totalMasks where mask.nonzeroBitCount == deletionCount {
                var rangeSet = RangeSet<Int>()
                for slotIndex in 0 ..< slots.count where (mask & (1 << slotIndex)) != 0 {
                    for range in slots[slotIndex].ranges {
                        rangeSet.insert(contentsOf: range.asRange)
                    }
                }

                var candidate = sequence
                candidate.removeSubranges(rangeSet)
                guard candidate.shortLexPrecedes(sequence) else { continue }
                guard rejectCache.contains(candidate) == false else { continue }
                guard let output = try? Interpreters.materialize(gen, with: tree, using: candidate) else {
                    rejectCache.insert(candidate)
                    continue
                }
                guard property(output) == false else {
                    rejectCache.insert(candidate)
                    continue
                }

                if bestCandidate == nil {
                    bestCandidate = candidate
                    bestOutput = output
                    bestDeletionCount = deletionCount
                    continue
                }

                if deletionCount > bestDeletionCount {
                    bestCandidate = candidate
                    bestOutput = output
                    bestDeletionCount = deletionCount
                    continue
                }

                if deletionCount == bestDeletionCount,
                   let currentBest = bestCandidate,
                   candidate.shortLexPrecedes(currentBest)
                {
                    bestCandidate = candidate
                    bestOutput = output
                }
            }

            if bestCandidate != nil {
                return (bestCandidate!, bestOutput!)
            }
        }

        return nil
    }

    private static func alignedContainerCohorts(
        in sequence: ChoiceSequence,
    ) -> [[AlignedDeletionSlot]] {
        let descriptors = ChoiceSequence.extractContainerSpans(from: sequence).compactMap { span in
            alignedContainerDescriptor(in: sequence, range: span.range, depth: span.depth)
        }
        guard descriptors.count >= 2 else { return [] }

        let sortedDescriptors = descriptors.sorted { lhs, rhs in
            lhs.range.lowerBound < rhs.range.lowerBound
        }

        var cohorts = [[AlignedDeletionSlot]]()
        for i in 0 ..< sortedDescriptors.count {
            let lhs = sortedDescriptors[i]
            for j in (i + 1) ..< sortedDescriptors.count {
                let rhs = sortedDescriptors[j]
                guard lhs.depth == rhs.depth else { continue }

                var slots = [AlignedDeletionSlot]()
                let sharedChildCount = min(lhs.children.count, rhs.children.count)
                if sharedChildCount == 0 { continue }

                for childIndex in 0 ..< sharedChildCount {
                    let leftChild = lhs.children[childIndex]
                    let rightChild = rhs.children[childIndex]
                    guard alignedChildrenMatch(leftChild, rightChild) else { continue }
                    slots.append(.init(ranges: [leftChild.range, rightChild.range]))
                }

                if slots.isEmpty == false {
                    cohorts.append(slots)
                }
            }
        }

        return cohorts
    }

    private static func alignedContainerDescriptor(
        in sequence: ChoiceSequence,
        range: ClosedRange<Int>,
        depth: Int,
    ) -> AlignedContainerDescriptor? {
        let children = effectiveAlignedChildren(in: sequence, from: range)
        guard !children.isEmpty else { return nil }

        var typedChildren = [AlignedContainerChild]()
        typedChildren.reserveCapacity(children.count)
        for child in children {
            if child.kind == .bareValue {
                guard child.range.lowerBound == child.range.upperBound,
                      let value = sequence[child.range.lowerBound].value
                else {
                    return nil
                }
                typedChildren.append(.init(range: child.range, kind: child.kind, valueTag: value.choice.tag))
            } else {
                typedChildren.append(.init(range: child.range, kind: child.kind, valueTag: nil))
            }
        }

        return .init(depth: depth, range: range, children: typedChildren)
    }

    private static func effectiveAlignedChildren(
        in sequence: ChoiceSequence,
        from range: ClosedRange<Int>,
    ) -> [(range: ClosedRange<Int>, kind: SiblingChildKind)] {
        var currentRange = range
        var remainingUnwraps = 16

        while remainingUnwraps > 0 {
            let children = ChoiceSequence.extractImmediateChildren(from: sequence, in: currentRange)
            guard !children.isEmpty else { return [] }

            // Skip trivial wrappers (e.g. zip/group wrappers around a single sequence child)
            // so alignment operates on the actual sibling elements.
            if children.count == 1, let only = children.first, only.kind != .bareValue, only.range != currentRange {
                currentRange = only.range
                remainingUnwraps -= 1
                continue
            }

            return children
        }

        return []
    }

    private static func alignedChildrenMatch(
        _ lhs: AlignedContainerChild,
        _ rhs: AlignedContainerChild,
    ) -> Bool {
        guard lhs.kind == rhs.kind else { return false }
        if lhs.kind == .bareValue {
            return lhs.valueTag == rhs.valueTag
        }
        return true
    }
}
