/// Tries primitive, small-scale, geometric, and nearby rescalings before coherent proposals, then shares each Cartesian diagonal across retained groups. Only index tuples are enumerated; candidate histories are written into the caller's reusable buffer.
struct NumericJointSearchCursor {
    private struct Plan {
        let leaves: [NumericPairQuery.Leaf]
        let samples: [[UInt64]]
        let ratioPatterns: Set<[UInt64]>
    }

    private let plans: [Plan]
    private let rescalingProposals: [Proposal]
    private var rescalingIndex = 0
    private var coherentRank = 0
    private var planIndex = 0
    private var diagonal = 0
    private var prefix: [Int]
    private var offsets: [Int]?
    private let maximumDiagonal: Int

    /// Preserves scope rank within each rescaling priority and records membership once for deduplicating the later grid.
    init(groups: [NumericJointQuery.Group]) {
        plans = groups.compactMap { group in
            let samples = group.samples
            guard samples.allSatisfy({ $0.isEmpty == false }) else { return nil }
            return Plan(leaves: group.leaves, samples: samples, ratioPatterns: Set(group.ratioProposals.map(\.patterns)))
        }
        rescalingProposals = groups.enumerated().flatMap { groupIndex, group in
            group.ratioProposals.map { rescaling in
                (priority: rescaling.priority, groupIndex: groupIndex, proposal: Proposal(leaves: group.leaves, patterns: rescaling.patterns))
            }
        }.sorted { first, second in
            if first.priority != second.priority { return first.priority < second.priority }
            return first.groupIndex < second.groupIndex
        }.map(\.proposal)
        prefix = Array(repeating: 0, count: max(0, (groups.first?.leaves.count ?? 1) - 1))
        maximumDiagonal = plans.map { $0.samples.reduce(0) { $0 + $1.count - 1 } }.max() ?? -1
    }

    struct Proposal {
        let leaves: [NumericPairQuery.Leaf]
        let patterns: [UInt64]
    }

    /// Shares each rescaling priority across retained groups before deepening to the next scale. All-target, all-halved, and mixed-rank grid points matching any earlier rescaling are skipped so prioritization does not spend extra probes on duplicates.
    mutating func next(into candidate: inout ChoiceSequence) -> Proposal? {
        if rescalingIndex < rescalingProposals.count {
            let proposal = rescalingProposals[rescalingIndex]
            rescalingIndex += 1
            return write(leaves: proposal.leaves, patterns: proposal.patterns, into: &candidate)
        }
        while coherentRank < 2 {
            while planIndex < plans.count {
                let plan = plans[planIndex]
                planIndex += 1
                let indices = Array(repeating: coherentRank, count: plan.leaves.count)
                if let proposal = proposal(plan: plan, indices: indices, into: &candidate) { return proposal }
            }
            planIndex = 0
            coherentRank += 1
        }
        while true {
            if offsets == nil {
                offsets = nextOffsets()
                guard offsets != nil else { return nil }
            }
            while planIndex < plans.count {
                let plan = plans[planIndex]
                planIndex += 1
                if let proposal = proposal(plan: plan, indices: offsets!, into: &candidate) { return proposal }
            }
            planIndex = 0
            offsets = nil
        }
    }

    private func proposal(plan: Plan, indices: [Int], into candidate: inout ChoiceSequence) -> Proposal? {
        guard indices.indices.allSatisfy({ indices[$0] < plan.samples[$0].count }) else { return nil }
        let patterns = indices.indices.map { plan.samples[$0][indices[$0]] }
        guard plan.ratioPatterns.contains(patterns) == false else { return nil }
        return write(leaves: plan.leaves, patterns: patterns, into: &candidate)
    }

    private func write(leaves: [NumericPairQuery.Leaf], patterns: [UInt64], into candidate: inout ChoiceSequence) -> Proposal {
        for index in leaves.indices {
            let position = leaves[index].position
            candidate[position] = candidate[position].withBitPattern(patterns[index])
        }
        return Proposal(leaves: leaves, patterns: patterns)
    }

    /// Enumerates bounded compositions of a rank sum using a base-six prefix and a derived final coordinate. Skips the two coherent rows already visited.
    private mutating func nextOffsets() -> [Int]? {
        while diagonal <= maximumDiagonal {
            let last = diagonal - prefix.reduce(0, +)
            let indices = prefix + [last]
            advancePrefix()
            guard (0 ..< 6).contains(last),
                  indices.allSatisfy({ $0 == 0 }) == false,
                  indices.allSatisfy({ $0 == 1 }) == false
            else { continue }
            return indices
        }
        return nil
    }

    private mutating func advancePrefix() {
        for index in prefix.indices.reversed() {
            prefix[index] += 1
            if prefix[index] < 6 { return }
            prefix[index] = 0
        }
        diagonal += 1
    }
}
