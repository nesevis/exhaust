// The mutation operators a generator's structure admits, read off a ChoiceGraph rather than off one draw's sequence positions.

/// Reads which ``MutationArm`` operators a generator can ever target, from a graph built over a tree materialized with `materializePicks: true`.
///
/// ``MutationTargets`` answers a narrower question: which operators can fire on one parent, at that parent's cached positions. Its queries walk ``ChoiceGraph/liveNodeIDs`` and drop children with no position range, which is every node under an unselected pick branch. A generator whose zip groups or repeated leaves live inside branch alternatives therefore looks barren from any single draw that did not take those branches.
///
/// This walk reads node kinds, children, and metadata alone, so an alternative carrying no sequence positions counts the same as the selected path. What it reports is a property of the generator, not of the draw: an operator sighted here is reachable, and no later draw can unsee it.
enum MutationArmRepertoire {
    /// The arms the graph's structure admits.
    ///
    /// The `low`, `medium`, and `high` bands are not reported: they run on the flat sequence and have no structural precondition. `typedCrossover` is reported on the presence of a pick fingerprint alone, because its second requirement, a donor span in another corpus entry, is a corpus fact that no single entry's structure can answer.
    static func sighted(in graph: ChoiceGraph) -> MutationArmSet {
        var sighted = MutationArmSet.none
        var leafTagCounts: [TypeTag: Int] = [:]

        for node in graph.nodes {
            switch node.kind {
                case let .chooseBits(metadata):
                    guard node.scopeAnnotation.isDepthControl == false,
                          node.scopeAnnotation.isLaneControl == false
                    else {
                        continue
                    }
                    leafTagCounts[metadata.typeTag, default: 0] += 1
                case .pick:
                    sighted.insert(.typedCrossover)
                case .bind:
                    sighted.insert(.splice)
                case .zip:
                    sighted = sighted.union(zipSightings(of: node, in: graph))
                case .sequence, .just:
                    continue
            }
        }

        if leafTagCounts.values.contains(where: { $0 >= 2 }) {
            sighted.insert(.lockstepDelta)
        }
        return sighted
    }

    /// The sibling-span and twin operators one zip node admits.
    ///
    /// Children are grouped twice under the two keys the operators themselves group by: ``PermutationQuery``'s shape partition for the span operators, and ``FuzzMutator/twinKey(of:)`` for the twin splice. Depth- and lane-control children are skipped here for the same reason those queries skip them, so a group of recursion markers is not mistaken for a swappable group.
    private static func zipSightings(of node: ChoiceGraphNode, in graph: ChoiceGraph) -> MutationArmSet {
        guard node.children.count >= 2 else {
            return .none
        }
        var shapeCounts: [StructuralShape: Int] = [:]
        var twinCounts: [FuzzMutator.TwinKey: Int] = [:]
        for childID in node.children {
            let child = graph.nodes[childID]
            guard child.scopeAnnotation.isDepthControl == false,
                  child.scopeAnnotation.isLaneControl == false
            else {
                continue
            }
            shapeCounts[shape(of: child), default: 0] += 1
            if let key = FuzzMutator.twinKey(of: child) {
                twinCounts[key, default: 0] += 1
            }
        }

        var sighted = MutationArmSet.none
        let largestGroup = shapeCounts.values.max() ?? 0
        if largestGroup >= 2 {
            sighted.insert(.swap)
            sighted.insert(.shuffle)
        }
        if largestGroup >= 3 {
            sighted.insert(.move)
        }
        if twinCounts.values.contains(where: { $0 >= 2 }) {
            sighted.insert(.twinSplice)
        }
        return sighted
    }

    // MARK: - Shape Key

    /// The partition ``PermutationQuery`` groups swappable siblings by, recomputed here because that query's own key is private to it and reachable only through scopes that have already dropped the inactive branches this walk exists to see.
    ///
    /// The two must agree: a coarser key here would sight `swap` on a parent the operator then cannot target, and a finer one would gate out a group the operator would have swapped.
    private enum StructuralShape: Hashable {
        case value
        case sequence(elementCount: Int)
        case zip(childCount: Int)
        case bind
        case pick(branchCount: UInt64)
        case just
    }

    private static func shape(of node: ChoiceGraphNode) -> StructuralShape {
        switch node.kind {
            case .chooseBits:
                .value
            case let .sequence(metadata):
                .sequence(elementCount: metadata.elementCount)
            case .zip:
                .zip(childCount: node.children.count)
            case .bind:
                .bind
            case let .pick(metadata):
                .pick(branchCount: metadata.branchCount)
            case .just:
                .just
        }
    }
}
