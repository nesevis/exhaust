//
//  ChoiceSequence.swift
//  Exhaust
//
//  Created by Chris Kolbu on 8/2/2026.
//

// MARK: - Academic Background

//
// Corresponds to the dissertation's bracketed choice sequences (Goldstein section 4.6). Shortlex ordering — shorter sequences are always simpler, with lexicographic comparison as tiebreaker, is from MacIver & Donaldson (ECOOP 2020, section 2.2). Zobrist hashing for O(1) incremental duplicate detection lives in ``ZobristHash``.

@usableFromInline
package typealias ChoiceSequence = ContiguousArray<ChoiceSequenceValue>

package extension Collection<ChoiceSequenceValue> {
    var shortString: String {
        map(\.shortString).joined()
    }
}

// MARK: - Helper functions

package extension ChoiceSequence {
    /// Creates a flat ``ChoiceSequence`` by flattening the given ``ChoiceTree``.
    init(_ tree: ChoiceTree) {
        self = Self.flatten(tree)
    }

    /// Flattens the tree structure of ``ChoiceTree`` to a flat list for mutation/reduction purposes.
    ///
    /// - Parameter includingAllBranches: When `true`, includes all branches at pick sites (not just the selected branch). Used for complexity comparison in reduction passes.
    /// - Parameter skipBindInners: When `true`, a bind's inner subtree is omitted from the flattened output, leaving `.bind(true) <bound> .bind(false)`. Used only to compute a canonical cluster identity: the inner is redundant length-or-selector bookkeeping that varies across reduction paths reaching the same value. Never use for materialisation or reduction, which need the inner.
    static func flatten(_ tree: ChoiceTree, includingAllBranches: Bool = false, skipBindInners: Bool = false) -> ChoiceSequence {
        var result = ChoiceSequence()
        result.reserveCapacity(64)
        flatten(tree, includingAllBranches: includingAllBranches, skipBindInners: skipBindInners, into: &result)
        return result
    }

    private static func flatten(
        _ tree: ChoiceTree,
        includingAllBranches: Bool,
        skipBindInners: Bool = false,
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
                output.append(.sequence(true, validRange: meta.validRange, isLengthExplicit: meta.isRangeExplicit))
                // while-loop: avoiding IteratorProtocol overhead in debug builds.
                var eIdx = 0
                while eIdx < elements.count {
                    flatten(elements[eIdx], includingAllBranches: includingAllBranches, skipBindInners: skipBindInners, into: &output)
                    eIdx += 1
                }
                output.append(.sequence(false))
            case let .branch(b):
                flatten(b.choice, includingAllBranches: includingAllBranches, skipBindInners: skipBindInners, into: &output)
            case let .group(array, _):
                var i = 0
                var selectedBranchTree: ChoiceTree?
                while i < array.count {
                    let candidate = array[i]
                    if candidate.isSelected {
                        selectedBranchTree = candidate
                        break
                    }
                    i += 1
                }
                if case let .branch(b) = selectedBranchTree, b.isSelected {
                    output.append(.group(true))
                    // The fingerprint must survive flattening: swarm masks key per-site masks on it, and dropping it here silently disabled masking for every pick site (the tree node always carries the source fingerprint; see Gen.pick).
                    output.append(.branch(.init(id: b.id, branchCount: b.branchCount, fingerprint: b.fingerprint)))
                    let children = includingAllBranches ? array : [b.choice]
                    // while-loop: avoiding IteratorProtocol overhead in debug builds.
                    var cIdx = 0
                    while cIdx < children.count {
                        flatten(
                            children[cIdx],
                            includingAllBranches: includingAllBranches, skipBindInners: skipBindInners,
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
                        flatten(array[aIdx], includingAllBranches: includingAllBranches, skipBindInners: skipBindInners, into: &output)
                        aIdx += 1
                    }
                    output.append(.group(false))
                }
            case let .bind(_, inner, bound):
                if inner.isGetSize {
                    // getSize-bound: structurally stable (size is fixed during reduction), so emit .group markers to let deletion encoders work through them.
                    output.append(.group(true))
                    flatten(inner, includingAllBranches: includingAllBranches, skipBindInners: skipBindInners, into: &output)
                    flatten(bound, includingAllBranches: includingAllBranches, skipBindInners: skipBindInners, into: &output)
                    output.append(.group(false))
                } else {
                    output.append(.bind(true))
                    if skipBindInners == false {
                        flatten(inner, includingAllBranches: includingAllBranches, skipBindInners: skipBindInners, into: &output)
                    }
                    flatten(bound, includingAllBranches: includingAllBranches, skipBindInners: skipBindInners, into: &output)
                    output.append(.bind(false))
                }
            case let .resize(_, choices):
                output.append(.group(true))
                // while-loop: avoiding IteratorProtocol overhead in debug builds.
                var rIdx = 0
                while rIdx < choices.count {
                    flatten(choices[rIdx], includingAllBranches: includingAllBranches, skipBindInners: skipBindInners, into: &output)
                    rIdx += 1
                }
                output.append(.group(false))
        }
    }

    static func validate(_ sequence: ChoiceSequence) -> Bool {
        var sequenceCount = 0
        var groupCount = 0
        var bindCount = 0
        for element in sequence {
            switch element {
                case .sequence(true, validRange: _, isLengthExplicit: _):
                    sequenceCount += 1
                case .sequence(false, validRange: _, isLengthExplicit: _):
                    sequenceCount -= 1
                case .group(true):
                    groupCount += 1
                case .group(false):
                    groupCount -= 1
                case .bind(true):
                    bindCount += 1
                case .bind(false):
                    bindCount -= 1
                case .value, .branch, .just:
                    break
            }
        }
        return sequenceCount == 0 && groupCount == 0 && bindCount == 0
    }

    /// Returns the flattened ``ChoiceValue``s within the given range, ignoring structural markers.
    /// Used as a lexicographic comparison key for sibling reordering.
    static func siblingComparisonKey(
        from sequence: ChoiceSequence,
        range: ClosedRange<Int>
    ) -> [ChoiceValue] {
        var keys: [ChoiceValue] = []
        // while-loop: avoiding IteratorProtocol overhead in debug builds.
        var i = range.lowerBound
        while i <= range.upperBound {
            switch sequence[i] {
                case let .value(v):
                    keys.append(v.choice)
                case .branch, .sequence, .group, .bind, .just:
                    break
            }
            i += 1
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
            while selfIdx < count, self[selfIdx].value == nil {
                selfIdx += 1
            }
            while otherIdx < other.count, other[otherIdx].value == nil {
                otherIdx += 1
            }
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
