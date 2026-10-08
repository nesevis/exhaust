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
    private let maximumOffsets: [Int]
    private let suffixCapacity: [Int]
    private let maximumDiagonal: Int

    /// Preserves scope rank within each rescaling priority and records membership once for deduplicating the later grid.
    init(groups: [NumericJointQuery.Group]) {
        let plans: [Plan] = groups.compactMap { group in
            let samples = group.samples
            guard samples.allSatisfy({ $0.isEmpty == false }) else { return nil }
            return Plan(leaves: group.leaves, samples: samples, ratioPatterns: Set(group.ratioProposals.map(\.patterns)))
        }
        self.plans = plans
        rescalingProposals = groups.enumerated().flatMap { groupIndex, group in
            group.ratioProposals.map { rescaling in
                (priority: rescaling.priority, groupIndex: groupIndex, proposal: Proposal(leaves: group.leaves, patterns: rescaling.patterns))
            }
        }.sorted { first, second in
            if first.priority != second.priority { return first.priority < second.priority }
            return first.groupIndex < second.groupIndex
        }.map(\.proposal)
        let arity = groups.first?.leaves.count ?? 0
        maximumOffsets = (0 ..< arity).map { index in
            plans.map { min($0.samples[index].count, NumericPairCandidates.maximumJointSamples) - 1 }.max() ?? 0
        }
        var capacity = Array(repeating: 0, count: arity + 1)
        for index in maximumOffsets.indices.reversed() {
            capacity[index] = maximumOffsets[index] + capacity[index + 1]
        }
        suffixCapacity = capacity
        prefix = Array(repeating: 0, count: max(0, arity - 1))
        maximumDiagonal = min(plans.map { $0.samples.reduce(0) { $0 + $1.count - 1 } }.max() ?? -1, capacity[0])
    }

    struct Proposal {
        let leaves: [NumericPairQuery.Leaf]
        let patterns: [UInt64]

        func write(into candidate: inout ChoiceSequence) {
            for index in leaves.indices {
                let position = leaves[index].position
                candidate[position] = candidate[position].withBitPattern(patterns[index])
            }
        }
    }

    mutating func next(into candidate: inout ChoiceSequence) -> Proposal? {
        guard let proposal = next() else { return nil }
        proposal.write(into: &candidate)
        return proposal
    }

    /// Shares each rescaling priority across retained groups before deepening to the next scale. All-target, all-halved, and mixed-rank grid points matching any earlier rescaling are skipped so prioritization does not spend extra probes on duplicates. No candidate is constructed until the caller needs one.
    mutating func next() -> Proposal? {
        if rescalingIndex < rescalingProposals.count {
            let proposal = rescalingProposals[rescalingIndex]
            rescalingIndex += 1
            return proposal
        }
        while coherentRank < 2 {
            while planIndex < plans.count {
                let plan = plans[planIndex]
                planIndex += 1
                let indices = Array(repeating: coherentRank, count: plan.leaves.count)
                if let proposal = proposal(plan: plan, indices: indices) { return proposal }
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
                if let proposal = proposal(plan: plan, indices: offsets!) { return proposal }
            }
            planIndex = 0
            offsets = nil
        }
    }

    private func proposal(plan: Plan, indices: [Int]) -> Proposal? {
        guard indices.indices.allSatisfy({ indices[$0] < plan.samples[$0].count }) else { return nil }
        let patterns = indices.indices.map { plan.samples[$0][indices[$0]] }
        guard plan.ratioPatterns.contains(patterns) == false else { return nil }
        return Proposal(leaves: plan.leaves, patterns: patterns)
    }

    /// Visits bounded compositions in lexicographic order within each rank sum, skipping the two coherent rows already visited.
    private mutating func nextOffsets() -> [Int]? {
        while diagonal <= maximumDiagonal {
            let last = diagonal - prefix.reduce(0, +)
            let indices = prefix + [last]
            advancePrefix()
            guard indices.allSatisfy({ $0 == 0 }) == false,
                  indices.allSatisfy({ $0 == 1 }) == false
            else { continue }
            return indices
        }
        return nil
    }

    private mutating func advancePrefix() {
        for index in prefix.indices.reversed() {
            var remaining = diagonal - prefix[..<index].reduce(0, +) - prefix[index] - 1
            guard prefix[index] < maximumOffsets[index], (0 ... suffixCapacity[index + 1]).contains(remaining) else { continue }
            prefix[index] += 1
            for following in (index + 1) ..< prefix.count {
                prefix[following] = max(0, remaining - suffixCapacity[following + 1])
                remaining -= prefix[following]
            }
            return
        }
        diagonal += 1
        guard diagonal <= maximumDiagonal else { return }
        var remaining = diagonal
        for index in prefix.indices {
            prefix[index] = max(0, remaining - suffixCapacity[index + 1])
            remaining -= prefix[index]
        }
    }
}
