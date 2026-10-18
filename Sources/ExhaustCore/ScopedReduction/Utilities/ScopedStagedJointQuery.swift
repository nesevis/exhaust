//
//  ScopedStagedJointQuery.swift
//  Exhaust
//

// MARK: - Staged Joint Query

/// Discovers the pairs and higher-order groups of one staged joint checkpoint.
///
/// A pair needs only a stalled source; its compensating partner may still be moving. Higher-order groups are discovered only after the preceding stage stalls.
///
/// Ranking is a heuristic: generator relationships and observed floor motion suggest property coupling but do not prove it. Discovery has its own limit, ``ScopedReductionTuning/numericJointGroupCalculationLimit``, separate from the probe budget. A leaf under a bind is eligible only when the bind's classification shows it lifts at both ends of its controller's range with the same bound shape at each. That checks only the two ends, so the candidate's ``DecoderAdmission`` still rejects any decoding that changes a proposed choice.
enum ScopedStagedJointQuery {
    /// One leaf of the candidate pool. Captures stalled membership as well as values and domains so new convergence evidence can reopen an exhausted checkpoint.
    struct Entry: Equatable {
        let leaf: ReductionLeaf
        let stalled: Bool
        let span: UInt64
        let simplifyingSamples: [UInt64]
        let compensatingSamples: [UInt64]
    }

    /// The groups one higher-order stage retains, with the discovery work spent finding them.
    struct Groups {
        let groups: [NumericJointQuery.Group]
        let calculations: Int
    }

    // MARK: - Pairs

    /// Collects the bounded pair scope, interleaving each source's nearest and farthest partners before any intermediate distance.
    ///
    /// - Parameter isFruitlessBind: Whether bound value search came back fruitless for the bind with this fingerprint.
    static func pairs(
        graph: ChoiceGraph,
        isFruitlessBind: (UInt64) -> Bool,
        tuning: ScopedReductionTuning
    ) -> [NumericPairQuery.Pair] {
        var pairs: [NumericPairQuery.Pair] = []
        let leaves = eligibleLeaves(graph: graph, tuning: tuning)
        guard leaves.count > 1 else {
            return []
        }
        let sourceIndices = leaves.indices.filter { isStalled(leaves[$0], graph: graph, isFruitlessBind: isFruitlessBind) }
        // Each source's nearest and farthest partners come first, alternating source by source, so neither distance class can take the whole cap.
        let lastIndex = leaves.count - 1
        let rounds = [[1, lastIndex]] + stride(from: 2, to: lastIndex, by: 1).map { [$0] }
        var seen: Set<Int> = []
        for offsets in rounds {
            for sourceIndex in sourceIndices {
                for offset in offsets {
                    let sinkIndex = min(sourceIndex + offset, lastIndex)
                    guard sinkIndex > sourceIndex,
                          seen.insert(sourceIndex * tuning.numericPairMaximumLeaves + sinkIndex).inserted
                    else {
                        continue
                    }
                    pairs.append(NumericPairQuery.Pair(source: leaves[sourceIndex], sink: leaves[sinkIndex]))
                    if pairs.count == tuning.numericPairMaximumPairs {
                        return pairs
                    }
                }
            }
        }
        return pairs
    }

    /// The numeric leaves pair and group discovery may use: at most ``ScopedReductionTuning/numericPairMaximumLeaves``, in position order, each under binds that lift at both ends of their controllers' ranges with the same bound shape at each.
    static func eligibleLeaves(graph: ChoiceGraph, tuning: ScopedReductionTuning) -> [ReductionLeaf] {
        // Filter before capping, so non-numeric leaves (a long string's characters, say) cannot use up the cap ahead of numeric ones.
        graph.leafNodes.lazy.compactMap { nodeID -> ReductionLeaf? in
            let node = graph.nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind,
                  let position = node.positionRange?.lowerBound,
                  NumericPairQuery.isNumeric(metadata),
                  supportsBinds(above: nodeID, graph: graph)
            else {
                return nil
            }
            return ReductionLeaf(
                nodeID: nodeID,
                position: position,
                path: node.choicePath,
                choice: metadata.value,
                range: metadata.validRange ?? metadata.typeTag.bitPatternRange,
                bindFingerprints: NumericPairQuery.bindFingerprints(above: nodeID, graph: graph),
                mayReshapeOnAcceptance: node.scopeAnnotation.isBindInner
            )
        }.prefix(tuning.numericPairMaximumLeaves).sorted { $0.position < $1.position }
    }

    /// Whether the leaf is off its target and stalled: its convergence floor sits at its current value, or it is a bind inner whose bound value search came back fruitless.
    static func isStalled(_ leaf: ReductionLeaf, graph: ChoiceGraph, isFruitlessBind: (UInt64) -> Bool) -> Bool {
        guard leaf.choice.bitPattern64 != leaf.choice.reductionTarget(in: leaf.range) else {
            return false
        }
        return graph.convergenceStore[leaf.nodeID]?.bound == leaf.choice.bitPattern64
            || (graph.nodes[leaf.nodeID].scopeAnnotation.isBindInner
                && isStalledBindInner(bindInnerLeafNodeID: leaf.nodeID, graph: graph, isFruitlessBind: isFruitlessBind))
    }

    /// Whether a bind inner is stalled: value search converged it at its current value, or its bind's bound value search came back fruitless, having tried lowering it under every downstream assignment in its covering.
    ///
    /// Bind inners are usually lowered by bound value search, whose upstream records no convergence, so a fruitless bound value search is the usual evidence.
    static func isStalledBindInner(bindInnerLeafNodeID: Int, graph: ChoiceGraph, isFruitlessBind: (UInt64) -> Bool) -> Bool {
        guard bindInnerLeafNodeID < graph.nodes.count,
              case let .chooseBits(metadata) = graph.nodes[bindInnerLeafNodeID].kind
        else {
            return false
        }
        if let record = graph.convergenceStore[bindInnerLeafNodeID],
           record.bound == metadata.value.bitPattern64
        {
            return true
        }
        guard let bindNodeID = graph.nodes[bindInnerLeafNodeID].scopeAnnotation.controllingBindNodeID,
              case let .bind(bindMetadata) = graph.nodes[bindNodeID].kind
        else {
            return false
        }
        return isFruitlessBind(bindMetadata.fingerprint)
    }

    // MARK: - Candidate Pool

    /// Collects the bounded pool of leaves that three-way and four-way groups are drawn from: stalled leaves first, then those nearest their target. Samples only the pool, keeping at-target leaves as compensating partners. The same samples feed both the work estimate and the eventual cursor, so the escalation gate measures the grid it will search. Higher-order proposals support integers and finite floating-point values, including mixed groups.
    ///
    /// Empty when escalation is disabled, so no preparation is spent.
    static func candidatePool(
        graph: ChoiceGraph,
        isFruitlessBind: (UInt64) -> Bool,
        tuning: ScopedReductionTuning
    ) -> [Entry] {
        guard tuning.threeWayNumericWorkLimit > 0,
              tuning.numericJointGroupCalculationLimit > 0,
              tuning.numericJointScopeLimit > 0
        else {
            return []
        }
        var leaves = eligibleLeaves(graph: graph, tuning: tuning)
        leaves.removeAll { $0.range.lowerBound == $0.range.upperBound }
        // A higher-order group needs at least three movable leaves. Avoid floor queries, ranking, and palette preparation when only pair search is possible.
        guard leaves.count >= 3 else {
            return []
        }
        return leaves.map { leaf in
            let target = leaf.choice.reductionTarget(in: leaf.range)
            let pattern = leaf.choice.bitPattern64
            let distance = pattern.absoluteDifference(target)
            return (
                leaf: leaf,
                stalled: isStalled(leaf, graph: graph, isFruitlessBind: isFruitlessBind),
                span: distance == UInt64.max ? UInt64.max : distance + 1
            )
        }.sorted { first, second in
            if first.stalled != second.stalled {
                return first.stalled
            }
            if first.span != second.span {
                return first.span < second.span
            }
            return first.leaf.position < second.leaf.position
        }.prefix(tuning.numericJointMaximumLeaves).sorted { $0.leaf.position < $1.leaf.position }.map { entry in
            Entry(
                leaf: entry.leaf,
                stalled: entry.stalled,
                span: entry.span,
                simplifyingSamples: NumericPairCandidates.jointValues(for: entry.leaf, simplifying: true),
                compensatingSamples: NumericPairCandidates.jointValues(for: entry.leaf, simplifying: false)
            )
        }
    }

    // MARK: - Higher-Order Groups

    /// Whether the search can widen to groups of `arity` leaves: the pool has at least `arity` stalled leaves, and some stalled first leaf's cheapest sampled grid fits `workLimit`. The cheapest grid multiplies the first leaf's simplifying samples by the smallest compensating sample counts among the leaves after it.
    ///
    /// An estimate: ``groups(candidatePool:graph:arity:workLimit:calculationLimit:scopeLimit:)`` also counts every extra ratio-preserving proposal against the limit, so it can still find no group. When this is false, it finds none. A large residual magnitude never makes it false.
    static func canWiden(to arity: Int, candidatePool: [Entry], workLimit: Int) -> Bool {
        guard (3 ... 4).contains(arity), workLimit > 0, candidatePool.count >= arity,
              candidatePool.count(where: \.stalled) >= arity
        else {
            return false
        }
        for sourceIndex in 0 ... candidatePool.count - arity where candidatePool[sourceIndex].stalled {
            let sourceCount = candidatePool[sourceIndex].simplifyingSamples.count
            let partnerCounts = candidatePool[(sourceIndex + 1)...].map { $0.compensatingSamples.count }
                .filter { $0 > 0 }.sorted().prefix(arity - 1)
            guard sourceCount > 0, partnerCounts.count == arity - 1 else {
                continue
            }
            let estimatedWork = partnerCounts.reduce(sourceCount, *)
            if estimatedWork <= workLimit {
                return true
            }
        }
        return false
    }

    /// Scores a bounded prefix of unique combinations, then packs ranked groups under both the retention and estimated-work limits. Work sums each sampled grid plus every ratio-preserving proposal outside that grid, bounding the complete retained search before the shared probe budget truncates exploration. The earliest edited leaf must be stalled and simplify; later leaves may move in either direction.
    static func groups(
        candidatePool: [Entry],
        graph: ChoiceGraph,
        arity: Int,
        workLimit: Int,
        calculationLimit: Int,
        scopeLimit: Int
    ) -> Groups {
        guard (3 ... 4).contains(arity), candidatePool.count >= arity,
              candidatePool.count(where: \.stalled) >= arity,
              workLimit > 0, calculationLimit > 0, scopeLimit > 0
        else {
            return Groups(groups: [], calculations: 0)
        }
        var selected = BoundedSortedBuffer<NumericJointQuery.Group>(limit: scopeLimit)
        var indices = Array(0 ..< arity)
        var calculations = 0
        repeat {
            calculations += 1
            guard candidatePool[indices[0]].stalled else {
                continue
            }
            var gridWork = 1
            for (offset, index) in indices.enumerated() {
                let entry = candidatePool[index]
                gridWork *= offset == 0 ? entry.simplifyingSamples.count : entry.compensatingSamples.count
            }
            guard gridWork > 0, gridWork <= workLimit else {
                continue
            }
            let entries = indices.map { candidatePool[$0] }
            let samples = entries.enumerated().map { index, entry in
                index == 0 ? entry.simplifyingSamples : entry.compensatingSamples
            }
            let leaves = entries.map(\.leaf)
            let ratioProposals = NumericCommonDivisorProposal.rescalings(for: leaves)
            let extraWork = ratioProposals.count { proposal in
                samples.indices.allSatisfy { samples[$0].contains(proposal.patterns[$0]) } == false
            }
            let estimatedWork = gridWork + extraWork
            if estimatedWork <= workLimit {
                var couplingCount = 0
                var sharedContextCount = 0
                for first in leaves.indices {
                    for second in leaves.indices where second > first {
                        let firstNode = leaves[first].nodeID
                        let secondNode = leaves[second].nodeID
                        if graph.couplingDependents[firstNode]?.contains(secondNode) == true
                            || graph.couplingDependents[secondNode]?.contains(firstNode) == true
                        { couplingCount += 1 }
                        if graph.nodes[firstNode].parent == graph.nodes[secondNode].parent {
                            sharedContextCount += 1
                        }
                    }
                }
                selected.insert(NumericJointQuery.Group(
                    leaves: leaves,
                    samples: samples,
                    ratioProposals: ratioProposals,
                    estimatedWork: estimatedWork,
                    residualVolume: saturatedVolume(entries.map(\.span)),
                    stalledCount: entries.count(where: \.stalled),
                    couplingCount: couplingCount,
                    sharedContextCount: sharedContextCount
                )) { $0.precedes($1) }
            }
        } while calculations < calculationLimit && advance(&indices, count: candidatePool.count)
        var groups: [NumericJointQuery.Group] = []
        var estimatedWork = 0
        for group in selected.elements where group.estimatedWork <= workLimit - estimatedWork {
            groups.append(group)
            estimatedWork += group.estimatedWork
        }
        return Groups(groups: groups, calculations: calculations)
    }

    // MARK: - Helpers

    /// Whether every non-constant bind above the leaf is classified as lifting at both ends of its controller's range with the same bound shape at each. An unclassified bind counts as unsupported: this reads cached classifications rather than classifying, which would cost materializations.
    private static func supportsBinds(above nodeID: Int, graph: ChoiceGraph) -> Bool {
        var ancestor = graph.nodes[nodeID].parent
        while let ancestorID = ancestor {
            let node = graph.nodes[ancestorID]
            if case let .bind(metadata) = node.kind, metadata.isStructurallyConstant == false {
                let classification = metadata.classification ?? graph.bindClassifications[metadata.fingerprint]
                guard classification?.topology == .identical, classification?.liftability == .both else {
                    return false
                }
            }
            ancestor = node.parent
        }
        return true
    }

    /// Keeps residual magnitude as a ranking hint without letting full-width products wrap or reject otherwise affordable grids.
    private static func saturatedVolume(_ spans: [UInt64]) -> UInt64 {
        var product: UInt64 = 1
        for span in spans {
            let (nextProduct, overflow) = product.multipliedReportingOverflow(by: span)
            guard overflow == false else {
                return UInt64.max
            }
            product = nextProduct
        }
        return product
    }

    /// Advances lexicographic combinations without constructing their discarded tail.
    private static func advance(_ indices: inout [Int], count: Int) -> Bool {
        for index in indices.indices.reversed() where indices[index] < count - indices.count + index {
            indices[index] += 1
            for following in (index + 1) ..< indices.count {
                indices[following] = indices[following - 1] + 1
            }
            return true
        }
        return false
    }
}
