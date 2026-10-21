/// Prepares a selected numeric group's samples, priority edits, and work estimate for a search. Discovery ranks these plans; cursors consume them without rediscovering targets or rebuilding proposals.
struct NumericJointPlan {
    let leaves: [ReductionLeaf]
    let samples: [[UInt64]]
    /// Built once during discovery: the group's sign flip and ratio-preserving rescalings, which the cursor tries before the grid and the grid skips.
    let priorityProposals: [NumericPriorityProposal]
    let estimatedWork: Int
    let residualVolume: UInt64
    let stalledCount: Int
    let couplingCount: Int
    let sharedContextCount: Int

    /// Uses coupling and stall evidence before residual magnitude, so domain size does not outweigh stronger evidence of joint dependence.
    func precedes(_ other: Self) -> Bool {
        if couplingCount != other.couplingCount {
            return couplingCount > other.couplingCount
        }
        if stalledCount != other.stalledCount {
            return stalledCount > other.stalledCount
        }
        if sharedContextCount != other.sharedContextCount {
            return sharedContextCount > other.sharedContextCount
        }
        return residualVolume < other.residualVolume
    }

    /// Prepares simplifying and compensating samples for one selected leaf. Captures stalled membership as well as values and domains so new convergence evidence can reopen an exhausted checkpoint.
    struct LeafSamples: Equatable {
        let leaf: ReductionLeaf
        let stalled: Bool
        let span: UInt64
        let simplifyingSamples: [UInt64]
        let compensatingSamples: [UInt64]
    }

    /// Prepares the sampled grid and priority edits for one selected group, rejecting work that cannot fit before computing its ranking hints.
    static func prepare(_ entries: [LeafSamples], graph: ChoiceGraph, workLimit: Int) -> Self? {
        let samples = entries.enumerated().map { index, entry in
            index == 0 ? entry.simplifyingSamples : entry.compensatingSamples
        }
        let gridWork = samples.reduce(1) { $0 * $1.count }
        guard gridWork > 0, gridWork <= workLimit else {
            return nil
        }
        let leaves = entries.map(\.leaf)
        let priorityProposals = NumericPriorityProposal.build(for: leaves)
        let extraWork = priorityProposals.count { proposal in
            samples.indices.allSatisfy { samples[$0].contains(proposal.probe.patterns[$0]) } == false
        }
        let estimatedWork = gridWork + extraWork
        guard estimatedWork <= workLimit else {
            return nil
        }
        var couplingCount = 0
        var sharedContextCount = 0
        for first in leaves.indices {
            for second in leaves.indices where second > first {
                let firstNode = leaves[first].nodeID
                let secondNode = leaves[second].nodeID
                if graph.couplingDependents[firstNode]?.contains(secondNode) == true
                    || graph.couplingDependents[secondNode]?.contains(firstNode) == true
                {
                    couplingCount += 1
                }
                if graph.nodes[firstNode].parent == graph.nodes[secondNode].parent {
                    sharedContextCount += 1
                }
            }
        }
        return Self(
            leaves: leaves,
            samples: samples,
            priorityProposals: priorityProposals,
            estimatedWork: estimatedWork,
            residualVolume: saturatedVolume(entries.map(\.span)),
            stalledCount: entries.count(where: \.stalled),
            couplingCount: couplingCount,
            sharedContextCount: sharedContextCount
        )
    }

    /// Whether the search can widen to groups of `arity` leaves: the pool has at least `arity` stalled leaves, and some stalled first leaf's cheapest sampled grid fits `workLimit`. The cheapest grid multiplies the first leaf's simplifying samples by the smallest compensating sample counts among the leaves after it.
    ///
    /// An estimate: ``prepare(_:graph:workLimit:)`` also counts extra sign flips and ratio-preserving proposals against the limit, so it can still find no group. When this is false, it finds none. A large residual magnitude never makes it false.
    static func canFit(arity: Int, candidatePool: [LeafSamples], workLimit: Int) -> Bool {
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
}

// MARK: - Sample Preparation

extension NumericJointPlan.LeafSamples {
    /// Samples only retained leaves, keeping the work estimate and the eventual search on the same palettes.
    init(leaf: ReductionLeaf, stalled: Bool, span: UInt64) {
        self.init(
            leaf: leaf,
            stalled: stalled,
            span: span,
            simplifyingSamples: NumericPairCandidates.jointValues(for: leaf, simplifying: true),
            compensatingSamples: NumericPairCandidates.jointValues(for: leaf, simplifying: false)
        )
    }
}
