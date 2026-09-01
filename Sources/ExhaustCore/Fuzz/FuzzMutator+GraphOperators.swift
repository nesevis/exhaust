// Graph-targeted mutation operators over the admission-time scope caches.
//
// Each operator resolves its positions through the parent's stored ChoiceGraph and edits the candidate with the shared sequence writers. Positions are admission-time facts about the parent, so a candidate that has already drifted structurally under a stacked mutation may be mis-targeted; every range is therefore bounds-checked against the candidate, an out-of-range operator is a cheap miss, and guided materialization absorbs any structural error a blind application introduces.

extension FuzzMutator {
    // MARK: - Sibling-Span Operators

    /// Exchanges two same-shaped sibling spans from one swap-eligible group.
    ///
    /// Returns nil when no group has two or more members or the group's positions do not fit the candidate.
    static func swapSiblingSpans(
        _ candidate: ChoiceSequence,
        scopes: [PermutationScope],
        graph: ChoiceGraph,
        prng: inout Xoshiro256
    ) -> ChoiceSequence? {
        guard let group = pickSwappableGroup(scopes: scopes, minimumSize: 2, prng: &prng),
              let slots = positionSlots(of: group, graph: graph, within: candidate.count)
        else {
            return nil
        }
        let firstIndex = Int(prng.next(upperBound: UInt64(slots.count)))
        let offset = 1 + Int(prng.next(upperBound: UInt64(slots.count - 1)))
        let secondIndex = (firstIndex + offset) % slots.count
        return candidate.swappingSpans(slots[firstIndex].range, slots[secondIndex].range)
    }

    /// Permutes a swap-eligible sibling group with a uniformly random permutation.
    ///
    /// Returns nil when no group qualifies or the drawn permutation is the identity; the identity has probability 1/n! and is a cheap miss rather than a redraw, keeping PRNG consumption fixed per call.
    static func shuffleSiblingSpans(
        _ candidate: ChoiceSequence,
        scopes: [PermutationScope],
        graph: ChoiceGraph,
        prng: inout Xoshiro256
    ) -> ChoiceSequence? {
        guard let group = pickSwappableGroup(scopes: scopes, minimumSize: 2, prng: &prng),
              let slots = positionSlots(of: group, graph: graph, within: candidate.count)
        else {
            return nil
        }
        var permutation = Array(slots.indices)
        var index = permutation.count - 1
        while index > 0 {
            let other = Int(prng.next(upperBound: UInt64(index + 1)))
            permutation.swapAt(index, other)
            index -= 1
        }
        guard permutation != Array(slots.indices) else {
            return nil
        }
        return candidate.permutingSpans(ranges: slots.map { $0.range }, permutation: permutation)
    }

    /// Repositions one sibling span within its group, shifting the spans between the source and target slots by one.
    ///
    /// Requires a group of three or more members: within a pair, a move is a swap. Returns nil when no group qualifies or the group's positions do not fit the candidate.
    static func moveSiblingSpan(
        _ candidate: ChoiceSequence,
        scopes: [PermutationScope],
        graph: ChoiceGraph,
        prng: inout Xoshiro256
    ) -> ChoiceSequence? {
        guard let group = pickSwappableGroup(scopes: scopes, minimumSize: 3, prng: &prng),
              let slots = positionSlots(of: group, graph: graph, within: candidate.count)
        else {
            return nil
        }
        let source = Int(prng.next(upperBound: UInt64(slots.count)))
        let offset = 1 + Int(prng.next(upperBound: UInt64(slots.count - 1)))
        let target = (source + offset) % slots.count

        // Rotation permutation: the source span's content lands at the target slot and the spans between them shift one slot toward the source.
        var permutation = Array(slots.indices)
        if source < target {
            for destination in source ..< target {
                permutation[destination] = destination + 1
            }
        } else {
            for destination in (target + 1) ... source {
                permutation[destination] = destination - 1
            }
        }
        permutation[target] = source
        return candidate.permutingSpans(ranges: slots.map { $0.range }, permutation: permutation)
    }

    // MARK: - Lockstep Delta

    /// Shifts every member of one same-tag tandem group by a shared delta in a shared direction.
    ///
    /// The direction is a fair draw and the delta is log-uniform under ``FuzzTunables/lockstepDeltaExponentLimit``, so agreement between the members (equal values, fixed differences) survives the shift. Returns nil when no group has two members inside the candidate or the shift changes nothing.
    static func lockstepDelta(
        _ candidate: ChoiceSequence,
        tandem: TandemScope,
        graph: ChoiceGraph,
        prng: inout Xoshiro256
    ) -> ChoiceSequence? {
        guard let group = pickTandemGroup(tandem, prng: &prng) else {
            return nil
        }
        var entries: [(index: Int, entry: ChoiceSequenceValue)] = []
        entries.reserveCapacity(group.leaves.count)
        for leaf in group.leaves {
            guard let range = graph.nodes[leaf.nodeID].positionRange else {
                continue
            }
            let position = range.lowerBound
            guard position < candidate.count else {
                continue
            }
            entries.append((index: position, entry: candidate[position]))
        }
        guard entries.count >= 2 else {
            return nil
        }
        let shiftUpward = prng.next(upperBound: 2) == 0
        let exponent = prng.next(upperBound: FuzzTunables.lockstepDeltaExponentLimit)
        let delta = 1 &+ prng.next(upperBound: 1 << exponent)
        guard let shifted = candidate.shiftingGroup(
            entries: entries,
            tag: group.typeTag,
            shiftUpward: shiftUpward,
            delta: delta,
            usesFloatingSteps: group.typeTag.isFloatingPoint
        ) else {
            return nil
        }
        return shifted.candidate
    }

    // MARK: - Twin Detection

    /// Discriminates zip children the generator drew from the same site, so twin spans can be spliced onto one another.
    ///
    /// Picks and binds match by their site fingerprint. Sequences match by element type tag rather than shape, so twins of different lengths (two instruction lists) still group. Leaves match by type tag, zips by child count.
    private enum TwinKey: Hashable {
        case pick(UInt64)
        case bind(UInt64)
        case value(TypeTag)
        case elementSequence(TypeTag)
        case zip(childCount: Int)
    }

    /// Computes the twin-span groups of every zip node: position ranges of siblings sharing a twin key, in position order, groups ordered by first position.
    ///
    /// Group and member ordering is explicit rather than dictionary order so seeded runs replay identically across processes.
    static func twinSpanGroups(graph: ChoiceGraph) -> [[ClosedRange<Int>]] {
        var groups: [[ClosedRange<Int>]] = []
        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard case .zip = node.kind, node.children.count >= 2 else {
                continue
            }
            var rangesByKey: [TwinKey: [ClosedRange<Int>]] = [:]
            for childID in node.children {
                let child = graph.nodes[childID]
                guard let range = child.positionRange else {
                    continue
                }
                if child.scopeAnnotation.isDepthControl || child.scopeAnnotation.isLaneControl {
                    continue
                }
                guard let key = twinKey(of: child) else {
                    continue
                }
                rangesByKey[key, default: []].append(range)
            }
            let zipGroups = rangesByKey.values
                .filter { $0.count >= 2 }
                .map { $0.sorted { $0.lowerBound < $1.lowerBound } }
                .sorted { $0[0].lowerBound < $1[0].lowerBound }
            groups.append(contentsOf: zipGroups)
        }
        return groups
    }

    /// The twin key of one zip child, or nil for kinds with no twin identity (`just`, untagged sequences).
    private static func twinKey(of node: ChoiceGraphNode) -> TwinKey? {
        switch node.kind {
            case let .pick(metadata):
                .pick(metadata.fingerprint)
            case let .bind(metadata):
                .bind(metadata.fingerprint)
            case let .chooseBits(metadata):
                .value(metadata.typeTag)
            case let .sequence(metadata):
                metadata.elementTypeTag.map { .elementSequence($0) }
            case let .zip(metadata):
                metadata.isOpaque ? nil : .zip(childCount: node.children.count)
            case .just:
                nil
        }
    }

    // MARK: - Twin Splice

    /// Copies one twin span over a sibling twin span, creating structural agreement between them.
    ///
    /// The one-directional counterpart of ``swapSiblingSpans(_:scopes:graph:prng:)``: after the splice both spans hold the source content. Twin spans of different lengths shift the positions after the target; guided materialization absorbs the drift. Returns nil when the entry has no twin group or a chosen span does not fit the candidate.
    static func twinSplice(
        _ candidate: ChoiceSequence,
        twinSpanGroups: [[ClosedRange<Int>]],
        prng: inout Xoshiro256
    ) -> ChoiceSequence? {
        guard let group = pickRangeGroup(twinSpanGroups, prng: &prng) else {
            return nil
        }
        let sourceIndex = Int(prng.next(upperBound: UInt64(group.count)))
        let offset = 1 + Int(prng.next(upperBound: UInt64(group.count - 1)))
        let targetIndex = (sourceIndex + offset) % group.count
        let source = group[sourceIndex]
        let target = group[targetIndex]
        guard source.upperBound < candidate.count, target.upperBound < candidate.count else {
            return nil
        }
        return candidate.copyingSpan(from: source, onto: target)
    }

    // MARK: - Typed Crossover

    /// Replaces one pick subtree with a same-fingerprint span from a different corpus entry.
    ///
    /// The donor span is an admission-time fact about the donor's immutable sequence, so it always addresses the donor validly; only the recipient's target range is bounds-checked against the candidate. A drawn donor from the recipient's own entry is a cheap miss rather than a redraw, keeping PRNG consumption fixed per call. Returns nil when no fingerprint has both an active recipient pick and a donor row.
    static func typedCrossover(
        _ candidate: ChoiceSequence,
        parentHash: UInt64,
        graph: ChoiceGraph,
        corpus: FuzzCorpus,
        prng: inout Xoshiro256
    ) -> ChoiceSequence? {
        // Fingerprint order is explicit rather than dictionary order so seeded runs replay identically across processes.
        var eligible: [(fingerprint: UInt64, targets: [Int])] = []
        var totalWeight: UInt64 = 0
        for fingerprint in graph.selfSimilarityGroups.keys.sorted() {
            guard let targets = graph.selfSimilarityGroups[fingerprint],
                  targets.isEmpty == false,
                  let donors = corpus.donorSpansByFingerprint[fingerprint],
                  donors.isEmpty == false
            else {
                continue
            }
            eligible.append((fingerprint: fingerprint, targets: targets))
            totalWeight += UInt64(targets.count)
        }
        guard totalWeight > 0 else {
            return nil
        }

        var remaining = prng.next(upperBound: totalWeight)
        var chosen = eligible[eligible.count - 1]
        for entry in eligible {
            let weight = UInt64(entry.targets.count)
            if remaining < weight {
                chosen = entry
                break
            }
            remaining -= weight
        }

        let targetNodeID = chosen.targets[Int(prng.next(upperBound: UInt64(chosen.targets.count)))]
        guard let donors = corpus.donorSpansByFingerprint[chosen.fingerprint] else {
            return nil
        }
        let donor = donors[Int(prng.next(upperBound: UInt64(donors.count)))]
        guard let target = graph.nodes[targetNodeID].positionRange,
              target.upperBound < candidate.count,
              corpus.entries[donor.entryIndex].hash != parentHash
        else {
            return nil
        }
        return candidate.graftingSpan(
            from: corpus.entries[donor.entryIndex].sequence,
            at: donor.range,
            onto: target
        )
    }

    // MARK: - Scope Selection

    /// Picks one swap-eligible sibling group with `minimumSize` or more members, weighted by member count.
    private static func pickSwappableGroup(
        scopes: [PermutationScope],
        minimumSize: Int,
        prng: inout Xoshiro256
    ) -> [Int]? {
        var eligible: [[Int]] = []
        var totalWeight: UInt64 = 0
        for scope in scopes {
            for group in scope.swappableGroups where group.count >= minimumSize {
                eligible.append(group)
                totalWeight += UInt64(group.count)
            }
        }
        guard totalWeight > 0 else {
            return nil
        }
        var remaining = prng.next(upperBound: totalWeight)
        for group in eligible {
            let weight = UInt64(group.count)
            if remaining < weight {
                return group
            }
            remaining -= weight
        }
        return eligible[eligible.count - 1]
    }

    /// Picks one range group with two or more members, weighted by member count.
    private static func pickRangeGroup(
        _ groups: [[ClosedRange<Int>]],
        prng: inout Xoshiro256
    ) -> [ClosedRange<Int>]? {
        var totalWeight: UInt64 = 0
        for group in groups where group.count >= 2 {
            totalWeight += UInt64(group.count)
        }
        guard totalWeight > 0 else {
            return nil
        }
        var remaining = prng.next(upperBound: totalWeight)
        for group in groups where group.count >= 2 {
            let weight = UInt64(group.count)
            if remaining < weight {
                return group
            }
            remaining -= weight
        }
        return groups[groups.count - 1]
    }

    /// Picks one tandem group with two or more leaves, weighted by leaf count.
    private static func pickTandemGroup(
        _ scope: TandemScope,
        prng: inout Xoshiro256
    ) -> TandemGroup? {
        var totalWeight: UInt64 = 0
        for group in scope.groups where group.leaves.count >= 2 {
            totalWeight += UInt64(group.leaves.count)
        }
        guard totalWeight > 0 else {
            return nil
        }
        var remaining = prng.next(upperBound: totalWeight)
        for group in scope.groups where group.leaves.count >= 2 {
            let weight = UInt64(group.leaves.count)
            if remaining < weight {
                return group
            }
            remaining -= weight
        }
        return scope.groups[scope.groups.count - 1]
    }

    /// Resolves a sibling group's node IDs to position ranges sorted by position, or nil when any member is inactive or extends past the candidate.
    private static func positionSlots(
        of group: [Int],
        graph: ChoiceGraph,
        within count: Int
    ) -> [(nodeID: Int, range: ClosedRange<Int>)]? {
        var slots: [(nodeID: Int, range: ClosedRange<Int>)] = []
        slots.reserveCapacity(group.count)
        for nodeID in group {
            guard let range = graph.nodes[nodeID].positionRange, range.upperBound < count else {
                return nil
            }
            slots.append((nodeID: nodeID, range: range))
        }
        slots.sort { $0.range.lowerBound < $1.range.lowerBound }
        return slots
    }
}
