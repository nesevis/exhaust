/// Discovers higher-order groups only after the preceding search stage stalls. Scope ranking is heuristic: generator relationships and observed floor motion do not prove property coupling.
enum NumericJointQuery {
    static let maximumLeaves = 16

    /// Captures stalled membership as well as values and domains so new convergence evidence can reopen an exhausted checkpoint.
    struct Entry: Equatable {
        let leaf: NumericPairQuery.Leaf
        let stalled: Bool
        let span: UInt64
        let simplifyingSamples: [UInt64]
        let compensatingSamples: [UInt64]
    }

    /// Samples only the bounded frontier, retaining at-target leaves as compensating partners. These exact palettes supply both the work estimate and the eventual cursor, so the gate measures the grid it will search. Higher-order proposals currently support integers; floating-point search continues through the pair stage.
    static func frontier(graph: ChoiceGraph, gate: BoundValueGate) -> [Entry] {
        NumericPairQuery.eligibleLeaves(graph: graph).compactMap { leaf -> (leaf: NumericPairQuery.Leaf, stalled: Bool, span: UInt64)? in
            guard leaf.choice.tag.isFloatingPoint == false, leaf.range.lowerBound != leaf.range.upperBound else {
                return nil
            }
            let target = leaf.choice.reductionTarget(in: leaf.range)
            let pattern = leaf.choice.bitPattern64
            let distance = pattern > target ? pattern - target : target - pattern
            return (
                leaf: leaf,
                stalled: NumericPairQuery.isStalled(leaf, graph: graph, gate: gate),
                span: distance == UInt64.max ? UInt64.max : distance + 1
            )
        }.sorted { first, second in
            if first.stalled != second.stalled { return first.stalled }
            if first.span != second.span { return first.span < second.span }
            return first.leaf.position < second.leaf.position
        }.prefix(maximumLeaves).sorted { $0.leaf.position < $1.leaf.position }.map { entry in
            Entry(
                leaf: entry.leaf,
                stalled: entry.stalled,
                span: entry.span,
                simplifyingSamples: NumericPairCandidates.jointValues(for: entry.leaf, simplifying: true),
                compensatingSamples: NumericPairCandidates.jointValues(for: entry.leaf, simplifying: false)
            )
        }
    }

    /// Reserves higher-order budget when enough nontrivial leaves have stalled and the cheapest sampled-grid estimate fits. Actual discovery includes every extra ratio-preserving proposal in the work limit and waits until the preceding stage stalls; a large residual magnitude never closes this gate.
    static func canEscalate(frontier: [Entry], arity: Int, workLimit: Int) -> Bool {
        guard (3 ... 4).contains(arity), workLimit > 0, frontier.count >= arity,
              frontier.count(where: \.stalled) >= arity
        else { return false }
        for sourceIndex in 0 ... frontier.count - arity where frontier[sourceIndex].stalled {
            let sourceCount = frontier[sourceIndex].simplifyingSamples.count
            let partnerCounts = frontier[(sourceIndex + 1)...].map { $0.compensatingSamples.count }
                .filter { $0 > 0 }.sorted().prefix(arity - 1)
            guard sourceCount > 0, partnerCounts.count == arity - 1 else { continue }
            let estimatedWork = partnerCounts.reduce(sourceCount, *)
            if estimatedWork <= workLimit { return true }
        }
        return false
    }

    /// Ranks compact descriptors rather than materialized candidate histories.
    struct Group {
        let leaves: [NumericPairQuery.Leaf]
        let samples: [[UInt64]]
        let ratioProposals: [NumericCommonDivisorProposal.Rescaling]
        let estimatedWork: Int
        let residualVolume: UInt64
        let stalledCount: Int
        let couplingCount: Int
        let sharedContextCount: Int

        func precedes(_ other: Group) -> Bool {
            if couplingCount != other.couplingCount { return couplingCount > other.couplingCount }
            if stalledCount != other.stalledCount { return stalledCount > other.stalledCount }
            if sharedContextCount != other.sharedContextCount { return sharedContextCount > other.sharedContextCount }
            return residualVolume < other.residualVolume
        }
    }

    struct Result {
        let groups: [Group]
        let calculations: Int
        let estimatedWork: Int
    }

    /// Scores a bounded prefix of unique combinations, then packs ranked groups under both the retention and estimated-work limits. Work sums each sampled grid plus every ratio-preserving proposal outside that grid, bounding the complete retained search before the shared probe budget truncates exploration. The earliest edited leaf must be stalled and simplify; later leaves may move in either direction.
    static func build(
        frontier: [Entry],
        graph: ChoiceGraph,
        arity: Int,
        workLimit: Int,
        calculationLimit: Int,
        scopeLimit: Int
    ) -> Result {
        guard (3 ... 4).contains(arity), frontier.count >= arity,
              frontier.count(where: \.stalled) >= arity,
              workLimit > 0, calculationLimit > 0, scopeLimit > 0
        else { return Result(groups: [], calculations: 0, estimatedWork: 0) }
        var selected = BoundedSortedBuffer<Group>(limit: scopeLimit)
        var indices = Array(0 ..< arity)
        var calculations = 0
        repeat {
            calculations += 1
            guard frontier[indices[0]].stalled else { continue }
            var gridWork = 1
            for (offset, index) in indices.enumerated() {
                let entry = frontier[index]
                gridWork *= offset == 0 ? entry.simplifyingSamples.count : entry.compensatingSamples.count
            }
            guard gridWork > 0, gridWork <= workLimit else { continue }
            let entries = indices.map { frontier[$0] }
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
                selected.insert(Group(
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
        } while calculations < calculationLimit && advance(&indices, count: frontier.count)
        var groups: [Group] = []
        var estimatedWork = 0
        for group in selected.elements where group.estimatedWork <= workLimit - estimatedWork {
            groups.append(group)
            estimatedWork += group.estimatedWork
        }
        return Result(groups: groups, calculations: calculations, estimatedWork: estimatedWork)
    }

    /// Keeps residual magnitude as a ranking hint without letting full-width products wrap or reject otherwise affordable grids.
    private static func saturatedVolume(_ spans: [UInt64]) -> UInt64 {
        var product: UInt64 = 1
        for span in spans {
            let (nextProduct, overflow) = product.multipliedReportingOverflow(by: span)
            guard overflow == false else { return UInt64.max }
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
