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

    private struct AlignedContainerSignature: Hashable {
        let kindKeys: [UInt8]
        let valueTags: [TypeTag?]
    }

    private struct AlignedContainerDescriptor {
        let depth: Int
        let range: ClosedRange<Int>
        let signature: AlignedContainerSignature
        let children: [AlignedContainerChild]
    }

    private struct AlignedCohortKey: Hashable {
        let depth: Int
        let signature: AlignedContainerSignature
    }

    /// Coordinated deletion across structurally aligned sibling containers.
    /// Builds cohorts of siblings with matching immediate child signatures, then deletes aligned
    /// child windows from all containers in a cohort in one candidate.
    ///
    /// - Complexity: O(*g* · *c* · *n* · log *n* · *M*), where *g* is sibling group count, *c* is
    ///   cohorts per group, *n* is child count per cohort, and *M* is one oracle call.
    static func deleteAlignedSiblingWindows<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        siblingGroups _: [SiblingGroup],
        rejectCache: inout ReducerCache,
    ) throws -> (ChoiceSequence, Output)? {
        let cohorts = alignedContainerCohorts(in: sequence)
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
                slotStart += 1
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
        var seenSignatures = Set<AlignedCohortKey>()
        for descriptor in sortedDescriptors {
            let key = AlignedCohortKey(depth: descriptor.depth, signature: descriptor.signature)
            guard seenSignatures.insert(key).inserted else { continue }

            let matches = sortedDescriptors.filter {
                $0.depth == descriptor.depth && $0.signature == descriptor.signature
            }
            guard matches.count >= 2 else { continue }
            guard let childCount = matches.first?.children.count, childCount > 0 else { continue }

            var slots = [AlignedDeletionSlot]()
            slots.reserveCapacity(childCount)
            for childIndex in 0 ..< childCount {
                let ranges = matches.map { $0.children[childIndex].range }
                slots.append(.init(ranges: ranges))
            }
            cohorts.append(slots)
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

        let signature = AlignedContainerSignature(
            kindKeys: typedChildren.map { siblingKindKey($0.kind) },
            valueTags: typedChildren.map(\.valueTag),
        )
        return .init(depth: depth, range: range, signature: signature, children: typedChildren)
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

    private static func siblingKindKey(_ kind: SiblingChildKind) -> UInt8 {
        switch kind {
        case .bareValue:
            return 0
        case .sequence:
            return 1
        case .group:
            return 2
        }
    }
}
