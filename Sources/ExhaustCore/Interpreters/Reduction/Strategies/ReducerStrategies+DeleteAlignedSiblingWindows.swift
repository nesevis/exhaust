//
//  ReducerStrategies+DeleteAlignedSiblingWindows.swift
//  Exhaust
//
//  Created by Chris Kolbu on 19/2/2026.
//

extension ReducerStrategies {
    typealias AlignedDeletionBeamSearchTuning = Interpreters.ShrinkConfiguration.AlignedDeletionBeamSearchTuning

    private struct AlignedDeletionSlot {
        let ranges: [ClosedRange<Int>]
    }

    private struct AlignedDeletionCohortRanges {
        let slotRangeSets: [RangeSet<Int>]
        let prefixUnions: [RangeSet<Int>]

        init(slots: [AlignedDeletionSlot]) {
            slotRangeSets = slots.map { slot in
                var rangeSet = RangeSet<Int>()
                for range in slot.ranges {
                    rangeSet.insert(contentsOf: range.asRange)
                }
                return rangeSet
            }

            var prefix = [RangeSet<Int>()]
            prefix.reserveCapacity(slotRangeSets.count + 1)
            for slotRangeSet in slotRangeSets {
                var next = prefix[prefix.count - 1]
                next.formUnion(slotRangeSet)
                prefix.append(next)
            }
            prefixUnions = prefix
        }

        var slotCount: Int {
            slotRangeSets.count
        }

        func contiguousRangeSet(slotStart: Int, size: Int) -> RangeSet<Int> {
            guard size > 0 else { return RangeSet<Int>() }
            var rangeSet = prefixUnions[slotStart + size]
            rangeSet.subtract(prefixUnions[slotStart])
            return rangeSet
        }

        func subsetRangeSet(mask: Int) -> RangeSet<Int> {
            var rangeSet = RangeSet<Int>()
            for slotIndex in 0 ..< slotRangeSets.count where (mask & (1 << slotIndex)) != 0 {
                rangeSet.formUnion(slotRangeSets[slotIndex])
            }
            return rangeSet
        }
    }

    private struct AlignedDeletionContext<Output> {
        let gen: ReflectiveGenerator<Output>
        let tree: ChoiceTree
        let onBudgetExhausted: ((String) -> Void)?
        var rejectCache: ReducerCache
        var budget: ProbeBudget
        var didReportBudgetExhaustion = false
        var budgetExhausted = false

        mutating func reportBudgetExhaustionIfNeeded() {
            guard budget.isExhausted, didReportBudgetExhaustion == false else { return }
            didReportBudgetExhaustion = true
            onBudgetExhausted?(budget.exhaustionReason)
        }
    }

    private struct AlignedDeletionBeamState {
        let mask: Int
        let lastAddedSlot: Int
        let deletionCount: Int
        let slotIndexSum: Int
        let heuristicScore: Int
        let rangeSet: RangeSet<Int>
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
        probeBudget: Int,
        subsetBeamSearchTuning: AlignedDeletionBeamSearchTuning,
        onBudgetExhausted: ((String) -> Void)? = nil,
    ) throws -> (ChoiceSequence, Output)? {
        let cohorts = alignedContainerCohorts(in: sequence)
            + alignedSiblingGroupCohorts(from: siblingGroups)
            + rootSequenceContainerCohorts(in: sequence)
        var context = AlignedDeletionContext(
            gen: gen,
            tree: tree,
            onBudgetExhausted: onBudgetExhausted,
            rejectCache: rejectCache,
            budget: ProbeBudget(passName: "deleteAlignedSiblingWindows", limit: probeBudget),
        )
        defer { rejectCache = context.rejectCache }

        guard context.budget.isExhausted == false else {
            context.reportBudgetExhaustionIfNeeded()
            return nil
        }

        for slots in cohorts where !slots.isEmpty {
            let cohortRanges = AlignedDeletionCohortRanges(slots: slots)
            var slotStart = 0
            while slotStart < slots.count {
                let maxBatch = slots.count - slotStart
                var bestCandidate: ChoiceSequence?
                var bestOutput: Output?
                var bestSize = 0

                let k = AdaptiveProbe.findInteger { (size: Int) -> Bool in
                    if context.budgetExhausted {
                        return false
                    }
                    guard size > 0 else { return true }
                    guard size <= maxBatch else { return false }
                    let rangeSet = cohortRanges.contiguousRangeSet(slotStart: slotStart, size: size)

                    var candidate = sequence
                    candidate.removeSubranges(rangeSet)

                    guard candidate.shortLexPrecedes(sequence) else { return false }
                    if let output = evaluateDeletionCandidate(
                        candidate: candidate,
                        property: property,
                        context: &context,
                    ) {
                        if size >= bestSize {
                            bestSize = size
                            bestCandidate = candidate
                            bestOutput = output
                        }
                        return true
                    }
                    return false
                }

                if context.budgetExhausted {
                    if let bestCandidate, let bestOutput {
                        return (bestCandidate, bestOutput)
                    }
                    return nil
                }

                if k > 0 {
                    if bestSize == k, let bestCandidate, let bestOutput {
                        return (bestCandidate, bestOutput)
                    }

                    let rangeSet = cohortRanges.contiguousRangeSet(slotStart: slotStart, size: k)
                    var candidate = sequence
                    candidate.removeSubranges(rangeSet)
                    let evaluatedOutput: Output? = evaluateDeletionCandidate(
                        candidate: candidate,
                        property: property,
                        context: &context,
                    )

                    if candidate.shortLexPrecedes(sequence),
                       let output = evaluatedOutput
                    {
                        return (candidate, output)
                    }
                    if context.budgetExhausted {
                        return nil
                    }
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
                        if context.budgetExhausted {
                            break
                        }
                        let rangeSet = cohortRanges.contiguousRangeSet(slotStart: slotStart, size: size)

                        var candidate = sequence
                        candidate.removeSubranges(rangeSet)
                        guard candidate.shortLexPrecedes(sequence) else { continue }
                        let evaluatedOutput: Output? = evaluateDeletionCandidate(
                            candidate: candidate,
                            property: property,
                            context: &context,
                        )
                        if let output = evaluatedOutput {
                            if size >= bestNonMonotoneSize {
                                bestNonMonotoneSize = size
                                bestNonMonotoneCandidate = candidate
                                bestNonMonotoneOutput = output
                            }
                        }
                    }

                    if let bestNonMonotoneCandidate, let bestNonMonotoneOutput {
                        return (bestNonMonotoneCandidate, bestNonMonotoneOutput)
                    }
                    if context.budgetExhausted {
                        return nil
                    }
                }
                slotStart += 1
            }

            // Bounded non-contiguous fallback for coupled cases where contiguous windows fail.
            let subsetResult: (ChoiceSequence, Output)? = bestSubsetDeletionCandidate(
                sequence: sequence,
                cohortRanges: cohortRanges,
                property: property,
                beamTuning: subsetBeamSearchTuning,
                context: &context,
            )
            if let (candidate, output) = subsetResult {
                return (candidate, output)
            }
            if context.budgetExhausted {
                return nil
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
            guard case .sequence(true, isLengthExplicit: _) = span.kind else { return false }
            guard span.range.lowerBound >= 0, span.range.upperBound < sequence.count else { return false }
            guard case .sequence(true, isLengthExplicit: _) = sequence[span.range.lowerBound],
                  case .sequence(false, isLengthExplicit: _) = sequence[span.range.upperBound]
            else { return false }
            return true
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
        sequence: ChoiceSequence,
        cohortRanges: AlignedDeletionCohortRanges,
        property: (Output) -> Bool,
        beamTuning: AlignedDeletionBeamSearchTuning,
        context: inout AlignedDeletionContext<Output>,
    ) -> (ChoiceSequence, Output)? {
        guard cohortRanges.slotCount >= 2 else { return nil }
        // We encode subsets as bitmasks.
        guard cohortRanges.slotCount < Int.bitWidth else { return nil }

        var bestCandidate: ChoiceSequence?
        var bestOutput: Output?
        var bestDeletionCount = 0

        let beamWidth = beamTuning.beamWidth(for: cohortRanges.slotCount)
        let evaluationsPerLayer = beamTuning.evaluationsPerLayer(
            for: cohortRanges.slotCount,
            beamWidth: beamWidth,
        )
        var frontier = [AlignedDeletionBeamState(
            mask: 0,
            lastAddedSlot: -1,
            deletionCount: 0,
            slotIndexSum: 0,
            heuristicScore: 0,
            rangeSet: RangeSet<Int>(),
        )]

        for layer in 1 ... cohortRanges.slotCount {
            if context.budgetExhausted {
                break
            }

            var expanded = [AlignedDeletionBeamState]()
            expanded.reserveCapacity(min(beamWidth * 2, beamWidth * max(1, cohortRanges.slotCount - layer + 1)))

            for state in frontier {
                let nextSlotStart = state.lastAddedSlot + 1
                guard nextSlotStart < cohortRanges.slotCount else { continue }

                for slotIndex in nextSlotStart ..< cohortRanges.slotCount {
                    let mask = state.mask | (1 << slotIndex)
                    let slotIndexSum = state.slotIndexSum + slotIndex
                    var rangeSet = state.rangeSet
                    rangeSet.formUnion(cohortRanges.slotRangeSets[slotIndex])
                    expanded.append(.init(
                        mask: mask,
                        lastAddedSlot: slotIndex,
                        deletionCount: layer,
                        slotIndexSum: slotIndexSum,
                        heuristicScore: beamHeuristicScore(
                            deletionCount: layer,
                            slotIndexSum: slotIndexSum,
                        ),
                        rangeSet: rangeSet,
                    ))
                }
            }

            guard expanded.isEmpty == false else { break }

            expanded.sort(by: beamStatePrecedes)
            if expanded.count > beamWidth {
                expanded.removeSubrange(beamWidth...)
            }
            frontier = expanded

            let evaluationCount = min(frontier.count, evaluationsPerLayer)
            for state in frontier.prefix(evaluationCount) {
                if context.budgetExhausted {
                    break
                }

                var candidate = sequence
                candidate.removeSubranges(state.rangeSet)
                guard candidate.shortLexPrecedes(sequence) else { continue }
                guard let output = evaluateDeletionCandidate(
                    candidate: candidate,
                    property: property,
                    context: &context,
                ) else {
                    continue
                }

                if bestCandidate == nil {
                    bestCandidate = candidate
                    bestOutput = output
                    bestDeletionCount = state.deletionCount
                    continue
                }

                if state.deletionCount > bestDeletionCount {
                    bestCandidate = candidate
                    bestOutput = output
                    bestDeletionCount = state.deletionCount
                    continue
                }

                if state.deletionCount == bestDeletionCount,
                   let currentBest = bestCandidate,
                   candidate.shortLexPrecedes(currentBest)
                {
                    bestCandidate = candidate
                    bestOutput = output
                }
            }
        }

        if let bestCandidate, let bestOutput {
            return (bestCandidate, bestOutput)
        }

        return nil
    }

    private static func beamHeuristicScore(
        deletionCount: Int,
        slotIndexSum: Int,
    ) -> Int {
        // Strongly prefer larger subsets and, within a subset size, earlier slots.
        (deletionCount * 1024) - slotIndexSum
    }

    private static func beamStatePrecedes(
        _ lhs: AlignedDeletionBeamState,
        _ rhs: AlignedDeletionBeamState,
    ) -> Bool {
        if lhs.deletionCount != rhs.deletionCount {
            return lhs.deletionCount > rhs.deletionCount
        }
        if lhs.heuristicScore != rhs.heuristicScore {
            return lhs.heuristicScore > rhs.heuristicScore
        }
        if lhs.slotIndexSum != rhs.slotIndexSum {
            return lhs.slotIndexSum < rhs.slotIndexSum
        }
        return lhs.mask < rhs.mask
    }

    private static func evaluateDeletionCandidate<Output>(
        candidate: ChoiceSequence,
        property: (Output) -> Bool,
        context: inout AlignedDeletionContext<Output>,
    ) -> Output? {
        guard context.rejectCache.contains(candidate) == false else {
            return nil
        }
        guard consumeBudget(context: &context) else {
            return nil
        }

        guard let output = try? Interpreters.materialize(
            context.gen,
            with: context.tree,
            using: candidate,
        ) else {
            context.rejectCache.insert(candidate)
            return nil
        }
        guard property(output) == false else {
            context.rejectCache.insert(candidate)
            return nil
        }
        return output
    }

    private static func consumeBudget(
        context: inout AlignedDeletionContext<some Any>,
    ) -> Bool {
        guard context.budget.consume() else {
            context.budgetExhausted = true
            context.reportBudgetExhaustionIfNeeded()
            return false
        }
        return true
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
