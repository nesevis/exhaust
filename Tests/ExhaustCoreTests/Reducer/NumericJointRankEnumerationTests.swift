import Testing
@testable import ExhaustCore

@Suite("Joint numeric rank enumeration")
struct NumericJointRankEnumerationTests {
    @Test("Bounded diagonals preserve the complete Cartesian proposal order", arguments: [3, 4], [false, true])
    func cartesianOrder(arity: Int, rescaled: Bool) throws {
        var bounds: [[Int]] = [[]]
        for _ in 0 ..< arity {
            bounds = bounds.flatMap { prefix in [1, 2, 6].map { prefix + [$0] } }
        }
        for counts in bounds {
            try compare(groups: [group(counts: counts, index: 0, rescaled: rescaled)])
        }
    }

    @Test("Unequal palettes share diagonals in retained group order", arguments: [3, 4], [false, true])
    func sharedOrder(arity: Int, rescaled: Bool) throws {
        let counts = arity == 3
            ? [[1, 6, 2], [6, 1, 3], [2, 3, 1]]
            : [[1, 6, 2, 3], [6, 1, 3, 2], [2, 3, 1, 6]]
        try compare(groups: counts.enumerated().map { group(counts: $0.element, index: $0.offset, rescaled: rescaled) })
    }

    @Test("Empty and unusable grids exhaust without proposing a tuple")
    func emptyGrids() throws {
        try compare(groups: [])
        try compare(groups: [group(counts: [0, 2, 6], index: 0, rescaled: false)])
    }

    private struct Snapshot: Equatable {
        let nodeIDs: [Int]
        let patterns: [UInt64]
    }

    private func compare(groups: [NumericJointQuery.Group]) throws {
        let expected = cartesianProposals(groups: groups)
        var cursor = NumericJointSearchCursor(groups: groups)
        var actual: [Snapshot] = []
        for _ in expected.indices {
            let next = cursor.next()
            let proposal = try #require(next)
            actual.append(.init(nodeIDs: proposal.leaves.map(\.nodeID), patterns: proposal.patterns))
        }
        #expect(actual == expected)
        #expect(cursor.next() == nil)
        #expect(cursor.next() == nil)
    }

    /// Builds the whole Cartesian product and sorts it independently of the production successor algorithm.
    private func cartesianProposals(groups: [NumericJointQuery.Group]) -> [Snapshot] {
        var rescalings: [(priority: Int, index: Int, patterns: [UInt64])] = []
        for (index, group) in groups.enumerated() {
            rescalings += group.ratioProposals.map { (priority: $0.priority, index: index, patterns: $0.patterns) }
        }
        rescalings.sort {
            $0.priority == $1.priority ? $0.index < $1.index : $0.priority < $1.priority
        }
        var result = rescalings.map { Snapshot(nodeIDs: groups[$0.index].leaves.map(\.nodeID), patterns: $0.patterns) }
        let plans = groups.filter { $0.samples.allSatisfy { $0.isEmpty == false } }
        guard let arity = plans.first?.leaves.count else { return result }
        func append(_ indices: [Int], group: NumericJointQuery.Group) {
            guard indices.indices.allSatisfy({ indices[$0] < group.samples[$0].count }) else { return }
            let patterns = indices.indices.map { group.samples[$0][indices[$0]] }
            guard group.ratioProposals.contains(where: { $0.patterns == patterns }) == false else { return }
            result.append(.init(nodeIDs: group.leaves.map(\.nodeID), patterns: patterns))
        }
        for rank in 0 ... 1 {
            for group in plans {
                append(Array(repeating: rank, count: arity), group: group)
            }
        }
        var tuples: Set<[Int]> = []
        for group in plans {
            var product: [[Int]] = [[]]
            for samples in group.samples {
                product = product.flatMap { prefix in samples.indices.map { prefix + [$0] } }
            }
            tuples.formUnion(product)
        }
        for indices in tuples.sorted(by: {
            let firstRank = $0.reduce(0, +)
            let secondRank = $1.reduce(0, +)
            return firstRank == secondRank ? $0.lexicographicallyPrecedes($1) : firstRank < secondRank
        }) where indices.allSatisfy({ $0 == 0 }) == false && indices.allSatisfy({ $0 == 1 }) == false {
            for group in plans {
                append(indices, group: group)
            }
        }
        return result
    }

    private func group(counts: [Int], index: Int, rescaled: Bool) -> NumericJointQuery.Group {
        let leaves = counts.indices.map { position in
            NumericPairQuery.Leaf(
                nodeID: index * counts.count + position,
                position: index * counts.count + position,
                path: [],
                choice: ChoiceValue(UInt64(100), tag: .uint64),
                range: 0 ... 100,
                bindFingerprints: [],
                mayReshapeOnAcceptance: false
            )
        }
        let ratios: [NumericCommonDivisorProposal.Rescaling] = rescaled
            ? [.init(priority: 0, patterns: Array(repeating: 1, count: counts.count)),
               .init(priority: 2, patterns: Array(repeating: 7, count: counts.count))]
            : []
        return .init(
            leaves: leaves,
            samples: counts.map { (0 ..< $0).map(UInt64.init) },
            ratioProposals: ratios,
            estimatedWork: counts.reduce(1, *) + ratios.count,
            residualVolume: 1,
            stalledCount: counts.count,
            couplingCount: 0,
            sharedContextCount: 0
        )
    }
}
