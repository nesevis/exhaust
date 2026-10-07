import Testing
@testable import ExhaustCore

@Suite("Coordinated common-divisor proposals")
struct NumericCommonDivisorTests {
    @Test("Common divisors rescale pairs, triples, and quadruples", arguments: [2, 3, 4])
    func everyArity(arity: Int) {
        let leaves = leaves(values: Array([75, 100, 125, 175].prefix(arity)).map { ChoiceValue(UInt64($0), tag: .uint64) })
        #expect(NumericCommonDivisorProposal.patterns(for: leaves) == Array([3, 4, 5, 7].prefix(arity)))
    }

    @Test("Primitive, small, geometric, and nearby scales are ordered and deduplicated", arguments: [2, 3, 4])
    func orderedRescalings(arity: Int) {
        let primitive = Array([UInt64(3), 4, 5, 7].prefix(arity))
        let leaves = leaves(values: primitive.map { ChoiceValue($0 * 25, tag: .uint64) })
        let proposals = NumericCommonDivisorProposal.rescalings(for: leaves)
        let expectedScales: [UInt64] = [1, 2, 3, 4, 12, 6, 24, 23, 22]
        #expect(proposals.map(\.patterns) == expectedScales.map { scale in primitive.map { $0 * scale } })
        #expect(proposals.map(\.priority) == [0, 1, 2, 3, 4, 5, 12, 13, 14])
        #expect(Set(proposals.map(\.patterns)).count == proposals.count)
    }

    @Test("Full-width rescaling remains bounded and preserves signs and zero")
    func boundedExtremeRescalings() {
        let leaves = leaves(values: [ChoiceValue(Int64.min, tag: .int64), ChoiceValue(UInt64(0), tag: .uint64), ChoiceValue(UInt64(1) << 63, tag: .uint64)])
        let proposals = NumericCommonDivisorProposal.rescalings(for: leaves)
        #expect(proposals.count == NumericCommonDivisorProposal.maximumProposals)
        for proposal in proposals {
            let scale = proposal.patterns[2]
            #expect(scale > 0 && scale < UInt64(1) << 63)
            #expect(proposal.patterns[0] == (UInt64(1) << 63) - scale)
            #expect(proposal.patterns[1] == 0)
        }
        let unsigned = self.leaves(values: [ChoiceValue(UInt64.max, tag: .uint64), ChoiceValue(UInt64(0), tag: .uint64)])
        #expect(NumericCommonDivisorProposal.rescalings(for: unsigned).count == NumericCommonDivisorProposal.maximumProposals)
    }

    @Test("A domain-excluded primitive tuple retains larger valid scales", arguments: [0, 1])
    func rescalingRangeAdmission(restricted: Int) {
        var ranges: [ClosedRange<UInt64>] = [1 ... 100, 1 ... 100]
        ranges[restricted] = 10 ... 100
        let leaves = leaves(values: [ChoiceValue(UInt64(75), tag: .uint64), ChoiceValue(UInt64(100), tag: .uint64)], ranges: ranges)
        let proposals = NumericCommonDivisorProposal.rescalings(for: leaves)
        #expect(proposals.first?.patterns == (restricted == 0 ? [12, 16] : [9, 12]))
        for proposal in proposals {
            #expect(proposal.patterns[0] * 4 == proposal.patterns[1] * 3)
            #expect(proposal.patterns.indices.allSatisfy { ranges[$0].contains(proposal.patterns[$0]) })
        }
    }

    @Test("Semantic rescaling preserves signs across different integer widths")
    func mixedSigns() {
        let leaves = leaves(values: [ChoiceValue(Int8(-75), tag: .int8), ChoiceValue(UInt64(100), tag: .uint64), ChoiceValue(Int16(-125), tag: .int16)])
        let expected = [ChoiceValue(Int8(-3), tag: .int8), ChoiceValue(UInt64(4), tag: .uint64), ChoiceValue(Int16(-5), tag: .int16)]
        #expect(NumericCommonDivisorProposal.patterns(for: leaves) == expected.map(\.bitPattern64))
    }

    @Test("Zero and signed minimum magnitudes rescale without absolute-value overflow")
    func extremeMagnitudes() {
        let leaves = leaves(values: [ChoiceValue(Int64.min, tag: .int64), ChoiceValue(UInt64(0), tag: .uint64), ChoiceValue(UInt64(1) << 63, tag: .uint64)])
        #expect(NumericCommonDivisorProposal.patterns(for: leaves) == [ChoiceValue(Int64(-1), tag: .int64).bitPattern64, 0, 1])
    }

    @Test("A trivial divisor, a zero source, and floating-point values supply no proposal")
    func ineligibleGroups() {
        #expect(NumericCommonDivisorProposal.patterns(for: leaves(values: [ChoiceValue(UInt64(3), tag: .uint64), ChoiceValue(UInt64(4), tag: .uint64)])) == nil)
        #expect(NumericCommonDivisorProposal.patterns(for: leaves(values: [ChoiceValue(UInt64(0), tag: .uint64), ChoiceValue(UInt64(0), tag: .uint64)])) == nil)
        #expect(NumericCommonDivisorProposal.patterns(for: leaves(values: [ChoiceValue(UInt64(0), tag: .uint64), ChoiceValue(UInt64(100), tag: .uint64)])) == nil)
        #expect(NumericCommonDivisorProposal.patterns(for: leaves(values: [ChoiceValue(75.0, tag: .double), ChoiceValue(100.0, tag: .double)])) == nil)
    }

    @Test("An out-of-range coordinate rejects the common scale without clamping", arguments: [0, 1])
    func rangeAdmission(restricted: Int) {
        var ranges: [ClosedRange<UInt64>] = [1 ... 100, 1 ... 100]
        ranges[restricted] = 10 ... 100
        let leaves = leaves(values: [ChoiceValue(UInt64(75), tag: .uint64), ChoiceValue(UInt64(100), tag: .uint64)], ranges: ranges)
        #expect(NumericCommonDivisorProposal.patterns(for: leaves) == nil)
    }

    @Test("Prioritizing a pair's common divisor does not repeat its grid point or leak skipped edits")
    func pairDeduplication() {
        let tree = unsignedTree(values: [3, 3, 3], range: 0 ... 3)
        var graph = ChoiceGraph.build(from: tree)
        markConverged(&graph)
        let pairs = NumericPairQuery.build(graph: graph, gate: .init(baseBudget: 15))
        #expect(pairs.count == 3)
        var cursor = StagedPairSearchCursor(pairs: pairs)
        let base = ChoiceSequence(tree)
        var observed: Set<[UInt64]> = []
        for _ in 0 ..< 28 {
            var candidate = base
            guard let proposal = cursor.next(into: &candidate) else { break }
            let changed = candidate.indices.filter { candidate[$0] != base[$0] }
            #expect(changed == [proposal.pair.source.position, proposal.pair.sink.position])
            #expect(candidate.shortLexPrecedes(base))
            let patterns = candidate.compactMap { $0.value?.choice.bitPattern64 }
            #expect(observed.insert(patterns).inserted)
        }
        #expect(observed.count == 27)
        var candidate = base
        #expect(cursor.next(into: &candidate) == nil)
    }

    @Test("All pairs reach their primitive tuple before any pair tries a larger scale")
    func pairPrioritySharing() throws {
        let tree = unsignedTree(values: [75, 100, 125], range: 1 ... 1_000_000)
        var graph = ChoiceGraph.build(from: tree)
        markConverged(&graph)
        let pairs = NumericPairQuery.build(graph: graph, gate: .init(baseBudget: 15))
        #expect(pairs.count == 3)
        var cursor = StagedPairSearchCursor(pairs: pairs)
        let base = ChoiceSequence(tree)
        for scale in UInt64(1) ... 2 {
            for pair in pairs {
                var candidate = base
                let next = cursor.next(into: &candidate)
                let proposal = try #require(next)
                #expect(proposal.pair == pair)
                #expect(proposal.sourceBitPattern == pair.source.choice.bitPattern64 / 25 * scale)
                #expect(proposal.sinkBitPattern == pair.sink.choice.bitPattern64 / 25 * scale)
            }
        }
    }

    @Test("All triples reach their primitive tuple before any triple tries a larger scale")
    func jointPrioritySharing() throws {
        let tree = unsignedTree(values: [75, 100, 125, 175], range: 1 ... 1_000_000)
        var graph = ChoiceGraph.build(from: tree)
        markConverged(&graph)
        let frontier = NumericJointQuery.frontier(graph: graph, gate: .init(baseBudget: 15))
        let scope = NumericJointQuery.build(frontier: frontier, graph: graph, arity: 3, workLimit: 4096, calculationLimit: 512, scopeLimit: 30)
        #expect(scope.groups.count == 4)
        var cursor = NumericJointSearchCursor(groups: scope.groups)
        let base = ChoiceSequence(tree)
        for scale in UInt64(1) ... 2 {
            for group in scope.groups {
                var candidate = base
                let next = cursor.next(into: &candidate)
                let proposal = try #require(next)
                #expect(proposal.leaves == group.leaves)
                #expect(proposal.patterns == group.leaves.map { $0.choice.bitPattern64 / 25 * scale })
            }
        }
    }

    @Test("Every off-grid rescaling adds one unit of work and emits once", arguments: [3, 4])
    func offGridWork(arity: Int) throws {
        let tree = unsignedTree(values: Array([75, 100, 125, 175].prefix(arity)), range: 1 ... 1_000_000)
        var graph = ChoiceGraph.build(from: tree)
        markConverged(&graph)
        let frontier = NumericJointQuery.frontier(graph: graph, gate: .init(baseBudget: 15))
        let gridWork = arity == 3 ? 216 : 1296
        let rejected = NumericJointQuery.build(frontier: frontier, graph: graph, arity: arity, workLimit: gridWork + 8, calculationLimit: 512, scopeLimit: 30)
        #expect(rejected.groups.isEmpty)
        let scope = NumericJointQuery.build(frontier: frontier, graph: graph, arity: arity, workLimit: gridWork + 9, calculationLimit: 512, scopeLimit: 30)
        let group = try #require(scope.groups.first)
        let expected = Array([UInt64(3), 4, 5, 7].prefix(arity))
        #expect(group.ratioProposals.first?.patterns == expected)
        #expect(group.ratioProposals.count == 9)
        #expect(scope.estimatedWork == gridWork + 9)
        var cursor = NumericJointSearchCursor(groups: scope.groups)
        let base = ChoiceSequence(tree)
        var candidate = base
        #expect(cursor.next(into: &candidate)?.patterns == expected)
        var observed: Set<[UInt64]> = [expected]
        for _ in 0 ... scope.estimatedWork {
            candidate = base
            guard let proposal = cursor.next(into: &candidate) else { break }
            #expect(candidate.shortLexPrecedes(base))
            #expect(observed.insert(proposal.patterns).inserted)
        }
        #expect(observed.count == scope.estimatedWork)
        candidate = base
        #expect(cursor.next(into: &candidate) == nil)
    }

    @Test("Staged search escapes primitive rejection using small, geometric, and nearby scales", arguments: [2, 3, 4], [3, 12, 24])
    func rejectedPrimitive(arity: Int, minimumScale: Int) throws {
        let primitive = Array([3, 4, 5, 7].prefix(arity))
        let initial = primitive.map { $0 * 25 }
        let generator = Gen.eachOf(Array(repeating: Gen.choose(in: 1 ... 1_000_000), count: arity))
        let tree = try #require(try Interpreters.reflect(generator, with: initial))
        var tuning = SchedulerTuning()
        tuning.fourWayNumericWorkLimit = 4096
        var machine = ReductionMachine(gen: generator, initialTree: tree, initialOutput: initial, config: .init(maxStalls: 2, enabledEncoders: [.stagedJointSearch], tuning: tuning), collectStats: true) { values in
            values[0] < primitive[0] * minimumScale || values.indices.contains { values[$0] * primitive[0] != values[0] * primitive[$0] }
        }
        machine.convergence.deferBindInner = false
        markConverged(&machine.graph)
        #expect(try machine.runStagedJointSearch())
        #expect(machine.output as? [Int] == primitive.map { $0 * minimumScale })
        #expect(machine.stats.numericSearchCountsByArity[arity]?.accepted == 1)
        let expectedProbes = [3: 3, 12: 5, 24: 7][minimumScale]!
        #expect(machine.stats.numericSearchCountsByArity[arity]?.emitted == expectedProbes)
        #expect(machine.stats.encoderCounts[.stagedJointSearch]!.emitted <= 512)
    }

    @Test("An unchanged zero is omitted from reported edits")
    func zeroIsNotReportedAsMovement() throws {
        let tree = unsignedTree(values: [75, 100, 0, 175], range: 0 ... 1000)
        var graph = ChoiceGraph.build(from: tree)
        markConverged(&graph)
        let frontier = NumericJointQuery.frontier(graph: graph, gate: .init(baseBudget: 15))
        let scope = NumericJointQuery.build(frontier: frontier, graph: graph, arity: 3, workLimit: 4096, calculationLimit: 512, scopeLimit: 30)
        let group = try #require(scope.groups.first { $0.leaves.map(\.choice.bitPattern64) == [75, 100, 0] })
        let leaves = group.leaves
        var encoder = StagedJointEncoder()
        encoder.start(scope: .init(transformation: .init(operation: .exchange(.numericJoint([group], probeBudget: 1)), priority: .zeroBenefit), baseSequence: ChoiceSequence(tree), tree: tree, graph: graph, warmStartRecords: [:]))
        var candidate = ChoiceSequence(tree)
        guard case let .leafValues(changes) = encoder.nextProbe(into: &candidate, lastAccepted: false) else {
            Issue.record("The common-divisor proposal must emit")
            return
        }
        #expect(changes.map(\.leafNodeID) == Array(leaves.prefix(2).map(\.nodeID)))
        #expect(candidate.compactMap { $0.value?.choice.bitPattern64 } == [3, 4, 0, 175])
    }

    private func leaves(values: [ChoiceValue], ranges: [ClosedRange<UInt64>]? = nil) -> [NumericPairQuery.Leaf] {
        let tree = ChoiceTree.group(values.enumerated().map { index, value in
            .choice(value, .init(validRange: ranges?[index] ?? value.tag.bitPatternRange, isRangeExplicit: true))
        })
        return NumericPairQuery.eligibleLeaves(graph: ChoiceGraph.build(from: tree))
    }

    private func unsignedTree(values: [UInt64], range: ClosedRange<UInt64>) -> ChoiceTree {
        .group(values.map { .choice(ChoiceValue($0, tag: .uint64), .init(validRange: range, isRangeExplicit: true)) })
    }

    private func markConverged(_ graph: inout ChoiceGraph) {
        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            graph.convergenceStore[nodeID] = ConvergedOrigin(bound: metadata.value.bitPattern64, signal: .monotoneConvergence, configuration: .binarySearchSemanticSimplest, cycle: 0)
        }
    }
}
