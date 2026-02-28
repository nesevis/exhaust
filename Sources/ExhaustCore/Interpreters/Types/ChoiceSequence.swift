//
//  ChoiceSequence.swift
//  Exhaust
//
//  Created by Chris Kolbu on 8/2/2026.
//

@_spi(ExhaustInternal) public struct ChoiceSpan: CustomDebugStringConvertible {
    @_spi(ExhaustInternal) public init(kind: ChoiceSequenceValue, range: ClosedRange<Int>, depth: Int) {
        self.kind = kind
        self.range = range
        self.depth = depth
    }

    @_spi(ExhaustInternal) public let kind: ChoiceSequenceValue
    @_spi(ExhaustInternal) public let range: ClosedRange<Int>
    @_spi(ExhaustInternal) public let depth: Int

    @_spi(ExhaustInternal) public var debugDescription: String {
        "<\(kind.shortString)> \(range.lowerBound)...\(range.upperBound) @ \(depth)"
    }
}

@_spi(ExhaustInternal) public typealias ChoiceSequence = ContiguousArray<ChoiceSequenceValue>

@_spi(ExhaustInternal) public extension Collection<ChoiceSequenceValue> {
    var shortString: String {
        map(\.shortString).joined()
    }
}

// MARK: - Helper functions

@_spi(ExhaustInternal) extension ChoiceSequence {
    /// Returns two independent hash values for use in a k-hash bloom filter.
    /// Uses the double-hashing scheme: index_i = (h1 + i * h2) % size.
    @_spi(ExhaustInternal) public var bloomHashes: (Int, Int) {
        var h1 = Hasher()
        var h2 = Hasher()
        h2.combine(0) // discriminator for independence
        for element in self {
            h1.combine(element)
            h2.combine(element)
        }
        return (h1.finalize(), h2.finalize())
    }

    /// Creates a projection of a `ChoiceTree` to a flat list
    @_spi(ExhaustInternal) public init(_ tree: ChoiceTree) {
        self = Self.flatten(tree)
    }

    /// Flattens the tree structure of ``ChoiceTree`` to a flat list for mutation/shrinking purposes
    @_spi(ExhaustInternal) public static func flatten(_ tree: ChoiceTree) -> ChoiceSequence {
        switch tree {
        case let .choice(value, meta):
            return [.value(.init(choice: value, validRanges: meta.validRanges, isRangeExplicit: meta.isRangeExplicit))]
        case .just:
            return []
        case let .sequence(_, elements, meta):
            return [.sequence(true, isLengthExplicit: meta.isRangeExplicit)]
                + elements.flatMap(flatten)
                + [.sequence(false)]
        // Do we only do the selected branch?
        case let .branch(_, _, _, _, gen):
            return flatten(gen)
        case let .group(array):
            if array.allSatisfy({ $0.isBranch || $0.isSelected }),
               case let .selected(.branch(_, _, id, branchIDs, choice)) = array.first(where: \.isSelected),
               choice.isCharacterChoice == false // Do not add this marker for characters
            {
                let value = ChoiceSequenceValue.branch(.init(
                    id: id,
                    validIDs: branchIDs,
                ))
                return [.group(true), value]
                    + flatten(choice)
                    + [.group(false)]
            }
            return [.group(true)]
                + array.flatMap(flatten)
                + [.group(false)]
        case .getSize:
            return []
        case let .resize(_, choices):
            return [.group(true)]
                + choices.flatMap(flatten)
                + [.group(false)]
        case let .selected(tree):
            return flatten(tree)
        }
    }

    /// Flattens the tree like ``flatten(_:)`` but includes ALL branches in pick-site groups,
    /// not just the selected branch. Used for complexity comparison in shrink passes.
    static func flattenAll(_ tree: ChoiceTree) -> ChoiceSequence {
        switch tree {
        case let .choice(value, meta):
            return [.value(.init(choice: value, validRanges: meta.validRanges, isRangeExplicit: meta.isRangeExplicit))]
        case .just:
            return []
        case let .sequence(_, elements, meta):
            return [.sequence(true, isLengthExplicit: meta.isRangeExplicit)]
                + elements.flatMap(flattenAll)
                + [.sequence(false)]
        case let .branch(_, _, _, _, gen):
            return flattenAll(gen)
        case let .group(array):
            if array.allSatisfy({ $0.isBranch || $0.isSelected }),
               case let .selected(.branch(_, _, id, branchIDs, choice)) = array.first(where: \.isSelected),
               choice.isCharacterChoice == false
            {
                let value = ChoiceSequenceValue.branch(.init(
                    id: id,
                    validIDs: branchIDs,
                ))
                return [.group(true), value]
                    + array.flatMap(flattenAll)
                    + [.group(false)]
            }
            return [.group(true)]
                + array.flatMap(flattenAll)
                + [.group(false)]
        case .getSize:
            return []
        case let .resize(_, choices):
            return [.group(true)]
                + choices.flatMap(flattenAll)
                + [.group(false)]
        case let .selected(tree):
            return flattenAll(tree)
        }
    }

    static func validate(_ sequence: ChoiceSequence) -> Bool {
        var sequenceCount = 0
        var groupCount = 0
        for element in sequence {
            switch element {
            case .sequence(true, isLengthExplicit: _):
                sequenceCount += 1
            case .sequence(false, isLengthExplicit: _):
                sequenceCount -= 1
            case .group(true):
                groupCount += 1
            case .group(false):
                groupCount -= 1
            case .value, .reduced, .branch:
                break
            }
        }
        return sequenceCount == 0 && groupCount == 0
    }

    @_spi(ExhaustInternal) public static func extractContainerSpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
        var spans: [ChoiceSpan] = []
        var stack: [(kind: ChoiceSequenceValue, start: Int)] = []
        // Maps stack depth to the span indices of children
        // collected while that frame was open
        var childrenAtDepth: [[Int]] = []

        for (i, entry) in sequence.enumerated() {
            switch entry {
            case .sequence(true, isLengthExplicit: _):
                stack.append((entry, i))
                childrenAtDepth.append([])

            case .group(true):
                stack.append((.group(true), i))
                childrenAtDepth.append([])

            case .sequence(false, isLengthExplicit: _), .group(false):
                guard let frame = stack.popLast() else { continue }

                let spanIndex = spans.count
                spans.append(ChoiceSpan(
                    kind: frame.kind,
                    range: frame.start ... i,
                    depth: stack.count,
                ))

                if case .sequence(true, isLengthExplicit: _) = frame.kind, frame.start < i - 1 {
                    // A span representing all the contents, not inclusive sequence markers
                    spans.append(ChoiceSpan(
                        kind: frame.kind,
                        range: (frame.start + 1) ... (i - 1),
                        depth: stack.count,
                    ))
                }

                // Register this span as a child of the enclosing frame
                if !childrenAtDepth.isEmpty {
                    childrenAtDepth[childrenAtDepth.count - 1].append(spanIndex)
                }

            case .value, .reduced, .branch:
                break
            }
        }

        return spans.sorted(by: { lhs, rhs in
            if lhs.depth == rhs.depth {
                if lhs.range.count == rhs.range.count {
                    return lhs.range.count < rhs.range.count
                }
                return lhs.range.lowerBound < rhs.range.lowerBound
            }
            return lhs.depth < rhs.depth
        })
    }

    /// Returns balanced group spans strictly contained within `range`, sorted longest-first.
    @_spi(ExhaustInternal) public static func extractDescendantGroupSpans(
        from sequence: ChoiceSequence,
        in range: ClosedRange<Int>,
    ) -> [ChoiceSpan] {
        guard !sequence.isEmpty else { return [] }
        guard range.lowerBound >= 0, range.upperBound < sequence.count else { return [] }

        var spans: [ChoiceSpan] = []
        var stack: [(start: Int, depth: Int)] = []
        var depth = 0

        for idx in range {
            switch sequence[idx] {
            case .group(true):
                stack.append((start: idx, depth: depth))
                depth += 1
            case .group(false):
                depth -= 1
                guard let frame = stack.popLast() else { continue }
                let spanRange = frame.start ... idx
                if spanRange.lowerBound > range.lowerBound,
                   spanRange.upperBound < range.upperBound
                {
                    spans.append(ChoiceSpan(
                        kind: .group(true),
                        range: spanRange,
                        depth: frame.depth,
                    ))
                }
            case .sequence(true, isLengthExplicit: _):
                depth += 1
            case .sequence(false, isLengthExplicit: _):
                depth -= 1
            case .value, .reduced, .branch:
                continue
            }
        }

        return spans.sorted { lhs, rhs in
            if lhs.range.count != rhs.range.count {
                return lhs.range.count > rhs.range.count
            }
            return lhs.range.lowerBound < rhs.range.lowerBound
        }
    }

    /// Returns spans representing `][` boundaries (`.sequence(false)` followed by `.sequence(true)`)
    /// that occur while nested inside an outer sequence (sequence depth > 1).
    /// Removing such a boundary merges two adjacent inner sequences into one.
    @_spi(ExhaustInternal) public static func extractSequenceBoundarySpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
        var spans: [ChoiceSpan] = []
        var sequenceDepth = 0

        for (i, entry) in sequence.enumerated() {
            switch entry {
            case .sequence(true, isLengthExplicit: _):
                sequenceDepth += 1
            case .sequence(false, isLengthExplicit: _):
                // Check if the next element is .sequence(true) and we're nested (depth > 1)
                if sequenceDepth > 1,
                   i + 1 < sequence.count,
                   case .sequence(true, isLengthExplicit: _) = sequence[i + 1]
                {
                    spans.append(ChoiceSpan(
                        kind: .sequence(false), // arbitrary; the span covers both markers
                        range: i ... i + 1,
                        depth: sequenceDepth,
                    ))
                }
                sequenceDepth -= 1
            default:
                break
            }
        }

        return spans
    }

    @_spi(ExhaustInternal) public static func extractAllValueSpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
        var spans: [ChoiceSpan] = []
        var depth = 0

        for (i, entry) in sequence.enumerated() {
            switch entry {
            case .value, .reduced:
                spans.append(ChoiceSpan(kind: entry, range: i ... i, depth: depth))
            case .group(true), .sequence(true, isLengthExplicit: _):
                depth += 1
            case .group(false), .sequence(false, isLengthExplicit: _):
                depth -= 1
            default:
                continue
            }
        }
        return spans.reversed()
    }

    /// Returns the spans of values not inside groups
    @_spi(ExhaustInternal) public static func extractFreeStandingValueSpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
        var spans: [ChoiceSpan] = []
        // Maps stack depth to the span indices of children
        // collected while that frame was open
        var depth = 0

        for (i, entry) in sequence.enumerated() {
            let preceding = i > 0 ? sequence[i - 1] : nil

            switch (preceding, entry) {
            case (nil, .value), (nil, .reduced):
                spans.append(ChoiceSpan(kind: entry, range: i ... i, depth: depth))
            case (.value, .value), (.reduced, .value), (.value, .reduced), (.reduced, .reduced):
                spans.append(ChoiceSpan(kind: entry, range: i ... i, depth: depth))
            case (.sequence(true, isLengthExplicit: _), .value), (.sequence(true, isLengthExplicit: _), .reduced):
                spans.append(ChoiceSpan(kind: entry, range: i ... i, depth: depth))
            case (_, .group(true)), (_, .sequence(true, isLengthExplicit: _)):
                depth += 1
            case (_, .group(false)), (_, .sequence(false, isLengthExplicit: _)):
                depth -= 1
            default:
                continue
            }
        }

        return spans.reversed()
    }

    mutating func removeSubranges(_ ranges: [ClosedRange<Int>]) {
        let set = RangeSet(ranges.map(\.asRange))
        removeSubranges(set)
    }

    // MARK: - Sibling groups

    /// Extracts groups of sibling elements within containers. A sibling group contains
    /// the immediate children of a sequence or group container, where all children are
    /// the same kind (all bare values or all containers of the same type).
    /// Only groups with >= 2 siblings are returned.
    static func extractSiblingGroups(from sequence: ChoiceSequence) -> [SiblingGroup] {
        var result: [SiblingGroup] = []
        var stack: [SiblingFrame] = []

        for (i, entry) in sequence.enumerated() {
            switch entry {
            case .sequence(true, isLengthExplicit: _):
                stack.append(SiblingFrame(depth: stack.count, startIndex: i, isSequence: true))

            case .group(true):
                stack.append(SiblingFrame(depth: stack.count, startIndex: i, isSequence: false))

            case .sequence(false, isLengthExplicit: _), .group(false):
                guard let frame = stack.popLast() else { continue }

                // Emit a sibling group if there are >= 2 children of homogeneous kind
                if frame.children.count >= 2 {
                    let firstKind = frame.children[0].kind
                    if frame.children.allSatisfy({ $0.kind == firstKind }) {
                        result.append(SiblingGroup(
                            ranges: frame.children.map(\.range),
                            depth: frame.depth,
                            kind: frame.children[0].kind,
                        ))
                    }
                }

                // Register this closed container as a child of the enclosing frame
                if !stack.isEmpty {
                    let childKind: SiblingChildKind = frame.isSequence ? .sequence : .group
                    stack[stack.count - 1].children.append(
                        (range: frame.startIndex ... i, kind: childKind),
                    )
                }

            case .value, .reduced:
                // A bare value is a single-index child of the current frame
                if !stack.isEmpty {
                    stack[stack.count - 1].children.append(
                        (range: i ... i, kind: .bareValue),
                    )
                }

            case .branch:
                // Branch markers are structural, skip them
                break
            }
        }

        return result.reversed()
    }

    /// Extracts immediate children of a single container range.
    /// Children are returned in-order and include bare values and immediate nested containers.
    static func extractImmediateChildren(
        from sequence: ChoiceSequence,
        in containerRange: ClosedRange<Int>,
    ) -> [(range: ClosedRange<Int>, kind: SiblingChildKind)] {
        guard !sequence.isEmpty else { return [] }
        guard containerRange.lowerBound >= 0, containerRange.upperBound < sequence.count else { return [] }

        let open = sequence[containerRange.lowerBound]
        let close = sequence[containerRange.upperBound]
        let isGroupContainer = open == .group(true) && close == .group(false)
        let isSequenceContainer: Bool
        if case .sequence(true, isLengthExplicit: _) = open, case .sequence(false, isLengthExplicit: _) = close {
            isSequenceContainer = true
        } else {
            isSequenceContainer = false
        }
        guard isGroupContainer || isSequenceContainer else { return [] }

        var children = [(range: ClosedRange<Int>, kind: SiblingChildKind)]()
        var index = containerRange.lowerBound + 1

        while index < containerRange.upperBound {
            switch sequence[index] {
            case .value, .reduced:
                children.append((range: index ... index, kind: .bareValue))
                index += 1

            case .group(true), .sequence(true, isLengthExplicit: _):
                let isGroupChild = sequence[index] == .group(true)
                let openEntry = sequence[index]
                let isSequenceEntry: Bool
                if case .sequence(true, isLengthExplicit: _) = openEntry { isSequenceEntry = true } else { isSequenceEntry = false }
                let start = index
                var depth = 1
                index += 1

                while index <= containerRange.upperBound, depth > 0 {
                    switch sequence[index] {
                    case .group(true) where openEntry == .group(true):
                        depth += 1
                    case .group(false) where openEntry == .group(true):
                        depth -= 1
                    case .sequence(true, isLengthExplicit: _) where isSequenceEntry:
                        depth += 1
                    case .sequence(false, isLengthExplicit: _) where isSequenceEntry:
                        depth -= 1
                    default:
                        break
                    }
                    if depth > 0 {
                        index += 1
                    }
                }

                guard depth == 0, index <= containerRange.upperBound else { return [] }
                children.append((range: start ... index, kind: isGroupChild ? .group : .sequence))
                index += 1

            case .branch:
                // Branch markers are structural and not standalone children.
                index += 1

            case .group(false), .sequence(false, isLengthExplicit: _):
                // Stray close marker inside the container; skip defensively.
                index += 1
            }
        }

        return children
    }

    /// Returns the flattened `ChoiceValue`s within the given range, ignoring structural markers.
    /// Used as a lexicographic comparison key for sibling reordering.
    static func siblingComparisonKey(
        from sequence: ChoiceSequence,
        range: ClosedRange<Int>,
    ) -> [ChoiceValue] {
        var keys: [ChoiceValue] = []
        for idx in range {
            switch sequence[idx] {
            case let .value(v), let .reduced(v):
                keys.append(v.choice)
            case .branch, .sequence, .group:
                continue
            }
        }
        return keys
    }

    func shortLexPrecedes(_ other: ChoiceSequence) -> Bool {
        // Shorter sequences are always better
        if count != other.count {
            return count < other.count
        }
        // Equal length compares lexicographically
        for (lhs, rhs) in zip(self, other) {
            switch lhs.shortLexCompare(rhs) {
            case .lt:
                return true
            case .gt:
                return false
            case .eq:
                continue
            }
        }
        return false // equal
    }
}
