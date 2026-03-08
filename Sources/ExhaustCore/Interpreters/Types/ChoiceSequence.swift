//
//  ChoiceSequence.swift
//  Exhaust
//
//  Created by Chris Kolbu on 8/2/2026.
//

public struct ChoiceSpan: CustomDebugStringConvertible {
    public init(kind: ChoiceSequenceValue, range: ClosedRange<Int>, depth: Int) {
        self.kind = kind
        self.range = range
        self.depth = depth
    }

    public let kind: ChoiceSequenceValue
    public let range: ClosedRange<Int>
    public let depth: Int

    public var debugDescription: String {
        "<\(kind.shortString)> \(range.lowerBound)...\(range.upperBound) @ \(depth)"
    }
}

public typealias ChoiceSequence = ContiguousArray<ChoiceSequenceValue>

public extension Collection<ChoiceSequenceValue> {
    var shortString: String {
        map(\.shortString).joined()
    }
}

// MARK: - Zobrist hashing

extension ChoiceSequence {
    /// Computes a Zobrist hash: XOR of position-dependent contributions for each element.
    /// Enables O(1) incremental updates when single elements change.
    internal var zobristHash: UInt64 {
        var hash: UInt64 = 0
        for (i, element) in self.enumerated() {
            hash ^= Self.zobristContribution(at: i, element)
        }
        return hash
    }

    /// Position-dependent hash contribution of a single element.
    /// Uses splitmix64 mixing for good avalanche with XOR combination.
    internal static func zobristContribution(at position: Int, _ value: ChoiceSequenceValue) -> UInt64 {
        var bits: UInt64
        switch value {
        case let .value(v):
            bits = v.choice.bitPattern64 ^ (zobristTagBits(v.choice.tag) << 48)
        case let .reduced(v):
            bits = v.choice.bitPattern64 ^ (zobristTagBits(v.choice.tag) << 48) ^ 0xFF00FF00FF00FF00
        case .sequence(true, isLengthExplicit: true):
            bits = 1
        case .sequence(true, isLengthExplicit: false):
            bits = 2
        case .sequence(false, isLengthExplicit: true):
            bits = 3
        case .sequence(false, isLengthExplicit: false):
            bits = 4
        case .group(true):
            bits = 5
        case .group(false):
            bits = 6
        case let .branch(b):
            bits = b.id ^ 0xDEADBEEFCAFEBABE
        case .just:
            bits = 7
        }
        bits ^= UInt64(position) &* 0x9E3779B97F4A7C15
        bits = (bits ^ (bits >> 30)) &* 0xBF58476D1CE4E5B9
        bits = (bits ^ (bits >> 27)) &* 0x94D049BB133111EB
        bits ^= bits >> 31
        return bits
    }

    /// Updates a Zobrist hash in O(1) after replacing the element at `position`.
    internal static func zobristHashUpdating(
        _ hash: UInt64,
        at position: Int,
        replacing oldValue: ChoiceSequenceValue,
        with newValue: ChoiceSequenceValue
    ) -> UInt64 {
        hash ^ zobristContribution(at: position, oldValue) ^ zobristContribution(at: position, newValue)
    }

    private static func zobristTagBits(_ tag: TypeTag) -> UInt64 {
        switch tag {
        case .uint: 0
        case .uint64: 1
        case .uint32: 2
        case .uint16: 3
        case .uint8: 4
        case .int: 5
        case .int64: 6
        case .int32: 7
        case .int16: 8
        case .int8: 9
        case .double: 10
        case .float: 11
        case .date: 12
        case .bits: 13
        }
    }
}

// MARK: - Helper functions

public extension ChoiceSequence {

    /// Creates a projection of a `ChoiceTree` to a flat list
    init(_ tree: ChoiceTree) {
        self = Self.flatten(tree)
    }

    /// Flattens the tree structure of ``ChoiceTree`` to a flat list for mutation/shrinking purposes.
    ///
    /// - Parameter includingAllBranches: When `true`, includes all branches at pick sites (not just the selected branch). Used for complexity comparison in shrink passes.
    static func flatten(_ tree: ChoiceTree, includingAllBranches: Bool = false) -> ChoiceSequence {
        var result = ChoiceSequence()
        result.reserveCapacity(64)
        flatten(tree, includingAllBranches: includingAllBranches, into: &result)
        return result
    }

    private static func flatten(
        _ tree: ChoiceTree,
        includingAllBranches: Bool,
        into output: inout ChoiceSequence
    ) {
        switch tree {
        case let .choice(value, meta):
            output.append(.value(.init(
                choice: value,
                validRange: meta.validRange,
                isRangeExplicit: meta.isRangeExplicit
            )))
        case .just:
            output.append(.just)
        case .getSize:
            break
        case let .sequence(_, elements, meta):
            output.append(.sequence(true, isLengthExplicit: meta.isRangeExplicit))
            for element in elements {
                flatten(element, includingAllBranches: includingAllBranches, into: &output)
            }
            output.append(.sequence(false))
        case let .branch(_, _, _, _, gen):
            flatten(gen, includingAllBranches: includingAllBranches, into: &output)
        case let .group(array):
            if array.allSatisfy({ $0.isBranch || $0.isSelected }),
               case let .selected(.branch(_, _, id, branchIDs, choice)) = array.first(where: \.isSelected)
            {
                output.append(.group(true))
                output.append(.branch(.init(id: id, validIDs: branchIDs)))
                let children = includingAllBranches ? array : [choice]
                for child in children {
                    flatten(child, includingAllBranches: includingAllBranches, into: &output)
                }
                output.append(.group(false))
            } else {
                output.append(.group(true))
                for child in array {
                    flatten(child, includingAllBranches: includingAllBranches, into: &output)
                }
                output.append(.group(false))
            }
        case let .resize(_, choices):
            output.append(.group(true))
            for choice in choices {
                flatten(choice, includingAllBranches: includingAllBranches, into: &output)
            }
            output.append(.group(false))
        case let .selected(tree):
            flatten(tree, includingAllBranches: includingAllBranches, into: &output)
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
            case .value, .reduced, .branch, .just:
                break
            }
        }
        return sequenceCount == 0 && groupCount == 0
    }

    static func extractContainerSpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
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

            case .value, .reduced, .branch, .just:
                break
            }
        }

        return spans.sorted(by: { lhs, rhs in
            if lhs.depth == rhs.depth {
                return lhs.range.lowerBound < rhs.range.lowerBound
            }
            return lhs.depth < rhs.depth
        })
    }

    /// Returns balanced group spans strictly contained within `range`, sorted longest-first.
    static func extractDescendantGroupSpans(
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
            case .value, .reduced, .branch, .just:
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

    /// Returns spans representing `][` boundaries (`.sequence(false)` followed by `.sequence(true)`) that occur while nested inside an outer sequence (sequence depth > 1).
    /// Removing such a boundary merges two adjacent inner sequences into one.
    static func extractSequenceBoundarySpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
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

    static func extractAllValueSpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
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
    static func extractFreeStandingValueSpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
        var spans: [ChoiceSpan] = []
        // Maps stack depth to the span indices of children
        // collected while that frame was open
        var depth = 0

        for (i, entry) in sequence.enumerated() {
            let preceding = i > 0 ? sequence[i - 1] : nil

            switch (preceding, entry) {
            case (nil, .value), (nil, .reduced):
                spans.append(ChoiceSpan(kind: entry, range: i ... i, depth: depth))
            case (.value, .value), (.reduced, .value), (.value, .reduced), (.reduced, .reduced),
                 (.just, .value), (.just, .reduced):
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

    internal mutating func removeSubranges(_ ranges: [ClosedRange<Int>]) {
        let set = RangeSet(ranges.map(\.asRange))
        removeSubranges(set)
    }

    // MARK: - Sibling groups

    /// Extracts groups of sibling elements within containers. A sibling group contains the immediate children of a sequence or group container, where all children are the same kind (all bare values or all containers of the same type).
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

            case .branch, .just:
                // Branch and just markers are structural, skip them
                break
            }
        }

        return result.reversed()
    }

    /// Extracts immediate children of a single container range.
    /// Children are returned in-order and include bare values and immediate nested containers.
    internal static func extractImmediateChildren(
        from sequence: ChoiceSequence,
        in containerRange: ClosedRange<Int>,
    ) -> [(range: ClosedRange<Int>, kind: SiblingChildKind)] {
        guard !sequence.isEmpty else { return [] }
        guard containerRange.lowerBound >= 0, containerRange.upperBound < sequence.count else { return [] }

        let open = sequence[containerRange.lowerBound]
        let close = sequence[containerRange.upperBound]
        let isGroupContainer = open == .group(true) && close == .group(false)
        let isSequenceContainer = if case .sequence(true, isLengthExplicit: _) = open, case .sequence(false, isLengthExplicit: _) = close {
            true
        } else {
            false
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
                let isSequenceEntry = if case .sequence(true, isLengthExplicit: _) = openEntry { true } else { false }
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

            case .branch, .just:
                // Branch and just markers are structural and not standalone children.
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
    internal static func siblingComparisonKey(
        from sequence: ChoiceSequence,
        range: ClosedRange<Int>,
    ) -> [ChoiceValue] {
        var keys: [ChoiceValue] = []
        for idx in range {
            switch sequence[idx] {
            case let .value(v), let .reduced(v):
                keys.append(v.choice)
            case .branch, .sequence, .group, .just:
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
