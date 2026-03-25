//
//  ChoiceSequence.swift
//  Exhaust
//
//  Created by Chris Kolbu on 8/2/2026.
//

// MARK: - Academic Provenance

//
// Corresponds to the dissertation's bracketed choice sequences (Goldstein §4.6). Shortlex ordering — shorter sequences are always simpler, with lexicographic comparison as tiebreaker — is from MacIver & Donaldson (ECOOP 2020, §2.2). Zobrist hashing for O(1) incremental duplicate detection lives in ``ZobristHash``.

/// A contiguous region of a ``ChoiceSequence``, identified by its kind, index range, and nesting depth.
public struct ChoiceSpan: CustomDebugStringConvertible {
    public init(kind: ChoiceSequenceValue, range: ClosedRange<Int>, depth: Int) {
        self.kind = kind
        self.range = range
        self.depth = depth
    }

    /// The ``ChoiceSequenceValue`` that opened this span.
    public let kind: ChoiceSequenceValue
    /// The index range within the ``ChoiceSequence`` that this span covers.
    public let range: ClosedRange<Int>
    /// The nesting depth of this span (0 = top level).
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

// MARK: - Helper functions

public extension ChoiceSequence {
    /// Creates a flat ``ChoiceSequence`` by flattening the given ``ChoiceTree``.
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
            // while-loop: avoiding IteratorProtocol overhead in debug builds.
            var eIdx = 0
            while eIdx < elements.count {
                flatten(elements[eIdx], includingAllBranches: includingAllBranches, into: &output)
                eIdx += 1
            }
            output.append(.sequence(false))
        case let .branch(_, _, _, _, gen):
            flatten(gen, includingAllBranches: includingAllBranches, into: &output)
        case let .group(array, _):
            if array.allSatisfy({ $0.isBranch || $0.isSelected }),
               case let .selected(.branch(_, _, id, branchIDs, choice)) =
                    array.first(where: \.isSelected)
            {
                output.append(.group(true))
                output.append(.branch(.init(id: id, validIDs: branchIDs)))
                let children = includingAllBranches ? array : [choice]
                // while-loop: avoiding IteratorProtocol overhead in debug builds.
                var cIdx = 0
                while cIdx < children.count {
                    flatten(
                        children[cIdx],
                        includingAllBranches: includingAllBranches,
                        into: &output
                    )
                    cIdx += 1
                }
                output.append(.group(false))
            } else {
                output.append(.group(true))
                // while-loop: avoiding IteratorProtocol overhead in debug builds.
                var aIdx = 0
                while aIdx < array.count {
                    flatten(array[aIdx], includingAllBranches: includingAllBranches, into: &output)
                    aIdx += 1
                }
                output.append(.group(false))
            }
        case let .bind(inner, bound):
            if inner.isGetSize {
                // getSize-bound: structurally stable (size is fixed during reduction),
                // so emit .group markers to let deletion encoders work through them.
                output.append(.group(true))
                flatten(inner, includingAllBranches: includingAllBranches, into: &output)
                flatten(bound, includingAllBranches: includingAllBranches, into: &output)
                output.append(.group(false))
            } else {
                output.append(.bind(true))
                flatten(inner, includingAllBranches: includingAllBranches, into: &output)
                flatten(bound, includingAllBranches: includingAllBranches, into: &output)
                output.append(.bind(false))
            }
        case let .resize(_, choices):
            output.append(.group(true))
            // while-loop: avoiding IteratorProtocol overhead in debug builds.
            var rIdx = 0
            while rIdx < choices.count {
                flatten(choices[rIdx], includingAllBranches: includingAllBranches, into: &output)
                rIdx += 1
            }
            output.append(.group(false))
        case let .selected(tree):
            flatten(tree, includingAllBranches: includingAllBranches, into: &output)
        }
    }

    static func validate(_ sequence: ChoiceSequence) -> Bool {
        var sequenceCount = 0
        var groupCount = 0
        var bindCount = 0
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
            case .bind(true):
                bindCount += 1
            case .bind(false):
                bindCount -= 1
            case .value, .reduced, .branch, .just:
                break
            }
        }
        return sequenceCount == 0 && groupCount == 0 && bindCount == 0
    }

    static func extractContainerSpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
        var spans: [ChoiceSpan] = []
        var stack: [(kind: ChoiceSequenceValue, start: Int)] = []
        // Maps stack depth to the span indices of children
        // collected while that frame was open
        var childrenAtDepth: [[Int]] = []

        // while-loop: avoiding IteratorProtocol overhead in debug builds.
        var i = 0
        while i < sequence.count {
            let entry = sequence[i]
            switch entry {
            case .sequence(true, isLengthExplicit: _):
                stack.append((entry, i))
                childrenAtDepth.append([])

            case .group(true):
                stack.append((.group(true), i))
                childrenAtDepth.append([])

            case .bind(true):
                stack.append((.bind(true), i))
                childrenAtDepth.append([])

            case .sequence(false, isLengthExplicit: _), .group(false), .bind(false):
                guard let frame = stack.popLast() else {
                    i += 1
                    continue
                }

                let spanIndex = spans.count
                spans.append(ChoiceSpan(
                    kind: frame.kind,
                    range: frame.start ... i,
                    depth: stack.count
                ))

                if case .sequence(true, isLengthExplicit: _) = frame.kind, frame.start < i - 1 {
                    // A span representing all the contents, not inclusive sequence markers
                    spans.append(ChoiceSpan(
                        kind: frame.kind,
                        range: (frame.start + 1) ... (i - 1),
                        depth: stack.count
                    ))
                }

                // Register this span as a child of the enclosing frame
                if !childrenAtDepth.isEmpty {
                    childrenAtDepth[childrenAtDepth.count - 1].append(spanIndex)
                }

            case .value, .reduced, .branch, .just:
                break
            }
            i += 1
        }

        return spans.sorted(by: { lhs, rhs in
            if lhs.depth == rhs.depth {
                return lhs.range.lowerBound < rhs.range.lowerBound
            }
            return lhs.depth < rhs.depth
        })
    }

    /// Returns group spans that are direct children of a sequence span, sorted by depth then position.
    ///
    /// These represent individual array elements. Deleting them changes the array length, so materialization should use `.relaxed` strictness to tolerate the structural shift.
    static func extractSequenceElementSpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
        var spans: [ChoiceSpan] = []
        var stack: [(kind: ChoiceSequenceValue, start: Int)] = []

        // while-loop: avoiding IteratorProtocol overhead in debug builds.
        var i = 0
        while i < sequence.count {
            let entry = sequence[i]
            switch entry {
            case .sequence(true, isLengthExplicit: _):
                stack.append((entry, i))

            case .group(true):
                stack.append((.group(true), i))

            case .bind(true):
                stack.append((.bind(true), i))

            case .group(false), .bind(false):
                guard let frame = stack.popLast() else {
                    i += 1
                    continue
                }
                guard case .group(true) = frame.kind else {
                    i += 1
                    continue
                }
                // Check if the parent frame (if any) is a sequence
                if let parent = stack.last,
                   case .sequence(true, isLengthExplicit: _) = parent.kind
                {
                    spans.append(ChoiceSpan(
                        kind: frame.kind,
                        range: frame.start ... i,
                        depth: stack.count
                    ))
                }

            case .sequence(false, isLengthExplicit: _):
                guard let _ = stack.popLast() else {
                    i += 1
                    continue
                }

            case .value, .reduced, .just:
                if let parent = stack.last,
                   case .sequence(true, isLengthExplicit: _) = parent.kind
                {
                    spans.append(ChoiceSpan(
                        kind: entry,
                        range: i ... i,
                        depth: stack.count
                    ))
                }

            case .branch:
                break
            }
            i += 1
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
        in range: ClosedRange<Int>
    ) -> [ChoiceSpan] {
        guard !sequence.isEmpty else { return [] }
        guard range.lowerBound >= 0, range.upperBound < sequence.count else { return [] }

        var spans: [ChoiceSpan] = []
        var stack: [(start: Int, depth: Int)] = []
        var depth = 0

        for idx in range {
            switch sequence[idx] {
            case .group(true), .bind(true):
                stack.append((start: idx, depth: depth))
                depth += 1
            case .group(false), .bind(false):
                depth -= 1
                guard let frame = stack.popLast() else { continue }
                let spanRange = frame.start ... idx
                if spanRange.lowerBound > range.lowerBound,
                   spanRange.upperBound < range.upperBound
                {
                    spans.append(ChoiceSpan(
                        kind: .group(true),
                        range: spanRange,
                        depth: frame.depth
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

        // while-loop: avoiding IteratorProtocol overhead in debug builds.
        var i = 0
        while i < sequence.count {
            let entry = sequence[i]
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
                        depth: sequenceDepth
                    ))
                }
                sequenceDepth -= 1
            default:
                break
            }
            i += 1
        }

        return spans
    }

    static func extractAllValueSpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
        var spans: [ChoiceSpan] = []
        var depth = 0

        // while-loop: avoiding IteratorProtocol overhead in debug builds.
        var i = 0
        while i < sequence.count {
            let entry = sequence[i]
            switch entry {
            case .value, .reduced:
                spans.append(ChoiceSpan(kind: entry, range: i ... i, depth: depth))
            case .group(true), .bind(true), .sequence(true, isLengthExplicit: _):
                depth += 1
            case .group(false), .bind(false), .sequence(false, isLengthExplicit: _):
                depth -= 1
            default:
                break
            }
            i += 1
        }
        return spans
    }

    /// Returns the spans of values not inside groups
    static func extractFreeStandingValueSpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
        var spans: [ChoiceSpan] = []
        // Maps stack depth to the span indices of children
        // collected while that frame was open
        var depth = 0

        // while-loop: avoiding IteratorProtocol overhead in debug builds.
        var i = 0
        while i < sequence.count {
            let entry = sequence[i]
            let preceding = i > 0 ? sequence[i - 1] : nil

            switch (preceding, entry) {
            case (nil, .value), (nil, .reduced):
                spans.append(ChoiceSpan(kind: entry, range: i ... i, depth: depth))
            case (.value, .value), (.reduced, .value), (.value, .reduced), (.reduced, .reduced),
                 (.just, .value), (.just, .reduced):
                spans.append(ChoiceSpan(kind: entry, range: i ... i, depth: depth))
            case (.sequence(true, isLengthExplicit: _), .value),
                 (.sequence(true, isLengthExplicit: _), .reduced):
                spans.append(ChoiceSpan(kind: entry, range: i ... i, depth: depth))
            case (_, .group(true)), (_, .bind(true)), (_, .sequence(true, isLengthExplicit: _)):
                depth += 1
            case (_, .group(false)), (_, .bind(false)), (_, .sequence(false, isLengthExplicit: _)):
                depth -= 1
            default:
                break
            }
            i += 1
        }

        return spans
    }

    mutating func removeSubranges(_ ranges: [ClosedRange<Int>]) {
        let set = RangeSet(ranges.map(\.asRange))
        removeSubranges(set)
    }

    // MARK: - Sibling groups

    /// Extracts groups of sibling elements within containers. A sibling group contains the immediate children of a sequence or group container, where all children are the same kind (all bare values or all containers of the same type).
    /// Only groups with >= 2 siblings are returned.
    static func extractSiblingGroups(from sequence: ChoiceSequence) -> [SiblingGroup] {
        var result: [SiblingGroup] = []
        var stack: [SiblingFrame] = []

        // while-loop: avoiding IteratorProtocol overhead in debug builds.
        var i = 0
        while i < sequence.count {
            let entry = sequence[i]
            switch entry {
            case .sequence(true, isLengthExplicit: _):
                stack.append(SiblingFrame(depth: stack.count, startIndex: i, isSequence: true))

            case .group(true), .bind(true):
                stack.append(SiblingFrame(depth: stack.count, startIndex: i, isSequence: false))

            case .sequence(false, isLengthExplicit: _), .group(false), .bind(false):
                guard let frame = stack.popLast() else {
                    i += 1
                    continue
                }

                // Emit a sibling group if there are >= 2 children of homogeneous kind
                if frame.children.count >= 2 {
                    let firstKind = frame.children[0].kind
                    if frame.children.allSatisfy({ $0.kind == firstKind }) {
                        result.append(SiblingGroup(
                            ranges: frame.children.map(\.range),
                            depth: frame.depth,
                            kind: frame.children[0].kind
                        ))
                    } else {
                        // Mixed-kind children: extract same-kind subsets so values of the
                        // same type can still be reduced in tandem across unrelated draws.
                        typealias SiblingChild = (
                            range: ClosedRange<Int>, kind: SiblingChildKind
                        )
                        var byKind = [SiblingChildKind: [SiblingChild]]()
                        for child in frame.children {
                            byKind[child.kind, default: []].append(child)
                        }
                        for (kind, children) in byKind where children.count >= 2 {
                            result.append(SiblingGroup(
                                ranges: children.map(\.range),
                                depth: frame.depth,
                                kind: kind
                            ))
                        }
                    }
                }

                // Register this closed container as a child of the enclosing frame
                if stack.isEmpty == false {
                    let childKind: SiblingChildKind = frame.isSequence ? .sequence : .group
                    stack[stack.count - 1].children.append(
                        (range: frame.startIndex ... i, kind: childKind)
                    )
                }

            case .value, .reduced:
                // A bare value is a single-index child of the current frame
                if stack.isEmpty == false {
                    stack[stack.count - 1].children.append(
                        (range: i ... i, kind: .bareValue)
                    )
                }

            case .branch, .just:
                // Branch and just markers are structural, skip them
                break
            }
            i += 1
        }

        return result
    }

    /// Extracts immediate children of a single container range.
    /// Children are returned in-order and include bare values and immediate nested containers.
    static func extractImmediateChildren(
        from sequence: ChoiceSequence,
        in containerRange: ClosedRange<Int>
    ) -> [(range: ClosedRange<Int>, kind: SiblingChildKind)] {
        guard !sequence.isEmpty else { return [] }
        guard containerRange.lowerBound >= 0,
              containerRange.upperBound < sequence.count
        else { return [] }

        let open = sequence[containerRange.lowerBound]
        let close = sequence[containerRange.upperBound]
        let isGroupContainer =
            (open == .group(true) && close == .group(false))
            || (open == .bind(true) && close == .bind(false))
        let isSequenceContainer =
            if case .sequence(true, isLengthExplicit: _) = open,
               case .sequence(false, isLengthExplicit: _) = close
            {
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

            case .group(true), .bind(true), .sequence(true, isLengthExplicit: _):
                let openEntry = sequence[index]
                let isGroupChild = openEntry == .group(true) || openEntry == .bind(true)
                let isSequenceEntry =
                    if case .sequence(true, isLengthExplicit: _) = openEntry {
                        true
                    } else {
                        false
                    }
                let start = index
                var depth = 1
                index += 1

                while index <= containerRange.upperBound, depth > 0 {
                    switch sequence[index] {
                    case .group(true) where openEntry == .group(true),
                         .bind(true) where openEntry == .bind(true):
                        depth += 1
                    case .group(false) where openEntry == .group(true),
                         .bind(false) where openEntry == .bind(true):
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

            case .group(false), .bind(false), .sequence(false, isLengthExplicit: _):
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
        range: ClosedRange<Int>
    ) -> [ChoiceValue] {
        var keys: [ChoiceValue] = []
        // while-loop: avoiding IteratorProtocol overhead in debug builds.
        var idx = range.lowerBound
        while idx <= range.upperBound {
            switch sequence[idx] {
            case let .value(v), let .reduced(v):
                keys.append(v.choice)
            case .branch, .sequence, .group, .bind, .just:
                break
            }
            idx += 1
        }
        return keys
    }

    /// Counts the number of aligned positions where two sequences differ under the shortlex ordering.
    ///
    /// Positions beyond the shorter sequence each count as one difference. Used as a cocartesian distance signal in fibration-based regime detection: a large distance indicates a lossy structural reduction; a small distance indicates a transparent one.
    static func shortlexDistance(_ lhs: ChoiceSequence, _ rhs: ChoiceSequence) -> Int {
        let minCount = Swift.min(lhs.count, rhs.count)
        var distance = abs(lhs.count - rhs.count)
        var i = 0
        while i < minCount {
            if lhs[i].shortLexCompare(rhs[i]) != .eq {
                distance += 1
            }
            i += 1
        }
        return distance
    }

    func shortLexPrecedes(_ other: ChoiceSequence) -> Bool {
        // Shorter sequences are always better
        if count != other.count {
            return count < other.count
        }
        // Equal length compares lexicographically.
        // while-loop: avoiding zip/IteratorProtocol overhead in debug builds.
        var i = 0
        while i < count {
            switch self[i].shortLexCompare(other[i]) {
            case .lt:
                return true
            case .gt:
                return false
            case .eq:
                i += 1
            }
        }
        return false // equal
    }
}
