//
//  AlignedDeletionCohortBuilder.swift
//  Exhaust
//
//  Created by Chris Kolbu on 14/3/2026.
//

// MARK: - Types

/// A single aligned deletion slot: the set of choice sequence ranges that would be removed together across sibling containers.
struct AlignedDeletionSlot {
    let ranges: [ClosedRange<Int>]
}

/// Precomputed range sets and prefix unions for a cohort's slots, enabling O(1) contiguous-window range set construction.
struct AlignedDeletionCohortRanges {
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
}

// MARK: - Supporting Types

/// A single child within an aligned container, carrying its range, structural kind, and optional value type tag for bare values.
struct AlignedContainerChild {
    let range: ClosedRange<Int>
    let kind: SiblingChildKind
    let valueTag: TypeTag?
}

/// Describes a container's structure for alignment matching: its bind depth, choice sequence range, and typed children.
struct AlignedContainerDescriptor {
    let depth: Int
    let range: ClosedRange<Int>
    let children: [AlignedContainerChild]
}

// MARK: - Cohort Builder

/// Builds deletion cohorts from structurally aligned sibling containers, sibling groups, and root sequence containers.
enum AlignedDeletionCohortBuilder {
    /// Builds all cohorts from a choice sequence and sibling groups.
    ///
    /// Combines three cohort-formation passes:
    /// 1. Aligned container pairs (structurally matched children)
    /// 2. Sibling group cohorts (from extracted sibling groups)
    /// 3. Root sequence container cohorts (content spans of top-level lists)
    static func buildCohorts(
        from sequence: ChoiceSequence,
        siblingGroups: [SiblingGroup],
    ) -> [[AlignedDeletionSlot]] {
        alignedContainerCohorts(in: sequence)
            + alignedSiblingGroupCohorts(from: siblingGroups)
            + rootSequenceContainerCohorts(in: sequence)
    }

    // MARK: - Sibling Group Cohorts

    private static func alignedSiblingGroupCohorts(
        from siblingGroups: [SiblingGroup],
    ) -> [[AlignedDeletionSlot]] {
        var cohorts = [[AlignedDeletionSlot]]()
        for group in siblingGroups where group.ranges.count >= 2 {
            if group.kind == .bareValue, group.ranges.count < 4 { continue }
            cohorts.append(group.ranges.map { AlignedDeletionSlot(ranges: [$0]) })
        }
        return cohorts
    }

    // MARK: - Root Sequence Container Cohorts

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

        let contentSlots = rootLevel.compactMap { span -> AlignedDeletionSlot? in
            let lower = span.range.lowerBound + 1
            let upper = span.range.upperBound - 1
            guard lower <= upper else { return nil }
            return AlignedDeletionSlot(ranges: [lower ... upper])
        }
        guard contentSlots.count >= 2 else { return [] }

        return [contentSlots]
    }

    // MARK: - Aligned Container Cohorts

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

    // MARK: - Helpers

    /// Extracts the aligned container descriptor for a given range, unwrapping single-child wrappers and typing bare value children.
    static func alignedContainerDescriptor(
        in sequence: ChoiceSequence,
        range: ClosedRange<Int>,
        depth: Int,
    ) -> AlignedContainerDescriptor? {
        let children = effectiveAlignedChildren(in: sequence, from: range)
        guard children.isEmpty == false else { return nil }

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

    /// Returns the effective children of a container range, unwrapping up to 16 layers of single-child wrapper nodes.
    static func effectiveAlignedChildren(
        in sequence: ChoiceSequence,
        from range: ClosedRange<Int>,
    ) -> [(range: ClosedRange<Int>, kind: SiblingChildKind)] {
        var currentRange = range
        var remainingUnwraps = 16

        while remainingUnwraps > 0 {
            let children = ChoiceSequence.extractImmediateChildren(from: sequence, in: currentRange)
            guard children.isEmpty == false else { return [] }

            if children.count == 1, let only = children.first, only.kind != .bareValue, only.range != currentRange {
                currentRange = only.range
                remainingUnwraps -= 1
                continue
            }

            return children
        }

        return []
    }

    static func alignedChildrenMatch(
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
