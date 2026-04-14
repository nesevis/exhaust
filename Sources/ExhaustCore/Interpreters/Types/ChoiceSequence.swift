//
//  ChoiceSequence.swift
//  Exhaust
//
//  Created by Chris Kolbu on 8/2/2026.
//

// MARK: - Academic Provenance

//
// Corresponds to the dissertation's bracketed choice sequences (Goldstein §4.6). Shortlex ordering — shorter sequences are always simpler, with lexicographic comparison as tiebreaker — is from MacIver & Donaldson (ECOOP 2020, §2.2). Zobrist hashing for O(1) incremental duplicate detection lives in ``ZobristHash``.

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

    /// Flattens the tree structure of ``ChoiceTree`` to a flat list for mutation/reduction purposes.
    ///
    /// - Parameter includingAllBranches: When `true`, includes all branches at pick sites (not just the selected branch). Used for complexity comparison in reduction passes.
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
            var idx = 0
            var selectedBranchTree: ChoiceTree?
            while idx < array.count {
                let candidate = array[idx]
                if candidate.isSelected, candidate.unwrapped.isBranch {
                    selectedBranchTree = candidate
                    break
                }
                idx += 1
            }
            if case let .selected(.branch(_, _, id, branchIDs, choice)) = selectedBranchTree {
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
    
    // MARK: - Shortlex

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
        // Value-projection tiebreaker: compare only value entries, ignoring structural noise that depends on generator argument order or tree topology rather than output simplicity.
        var selfIdx = 0
        var otherIdx = 0
        while selfIdx < count, otherIdx < other.count {
            while selfIdx < count, self[selfIdx].value == nil { selfIdx += 1 }
            while otherIdx < other.count, other[otherIdx].value == nil { otherIdx += 1 }
            guard selfIdx < count, otherIdx < other.count else { break }
            switch self[selfIdx].value!.shortLexCompare(other[otherIdx].value!) {
            case .lt: return true
            case .gt: return false
            case .eq:
                selfIdx += 1
                otherIdx += 1
            }
        }
        // Fewer remaining values wins.
        if selfIdx < count || otherIdx < other.count {
            let selfRemaining = (selfIdx ..< count).count { self[$0].value != nil }
            let otherRemaining = (otherIdx ..< other.count).count { other[$0].value != nil }
            if selfRemaining != otherRemaining {
                return selfRemaining < otherRemaining
            }
        }
        return false // equal
    }
}
