import Testing
@testable import ExhaustCore

@Suite("Reducer regressions")
struct ReducerRegressionTests {
    // MARK: - Convergence Confirmation

    @Test("Confirmation clears a stale floor on a leaf below its target", arguments: [
        ConfirmationCase(start: -5, failsAtOrBelow: -4),
        ConfirmationCase(start: 5, failsAtOrAbove: 4),
    ])
    func confirmationClearsStaleFloorTowardsTarget(_ confirmation: ConfirmationCase) throws {
        let generator = Gen.choose(in: Int64(-100) ... 100)
        let tree = try #require(try Interpreters.reflect(generator, with: confirmation.start))
        var runner = ReductionSession(
            generator: generator,
            initialTree: tree,
            initialOutput: confirmation.start,
            configuration: .init(maxStalls: 1),
            collectStats: false,
            property: { confirmation.fails($0) == false }
        )
        let leafNodeID = try #require(runner.graph.leafNodes.first)
        runner.graph.convergenceStore[leafNodeID] = ConvergedOrigin(
            bound: confirmation.start.bitPattern64,
            signal: .monotoneConvergence,
            configuration: .binarySearchSemanticSimplest,
            cycle: 0
        )

        let clearedStaleFloor = runner.confirmConvergence()

        #expect(clearedStaleFloor)
        #expect(runner.graph.convergenceStore[leafNodeID] == nil)
    }

    // MARK: - Dispatch After Rejection

    @Test("A swap the property refused is dispatched again, and accepted, after an unrelated accepted change")
    func refusedSwapIsRetriedAfterUnrelatedAcceptance() throws {
        let leaf = Gen.choose(in: UInt64(0) ... 10)
        let generator = Gen.zip(Gen.zip(leaf, leaf), leaf)
        let start: ((UInt64, UInt64), UInt64) = ((2, 1), 1)
        let tree = try #require(try Interpreters.reflect(generator, with: start))
        var runner = ReductionSession(
            generator: generator,
            initialTree: tree,
            initialOutput: start,
            configuration: .init(maxStalls: 2),
            collectStats: false,
            property: { value in value.0.0 < value.0.1 && value.1 != 0 }
        )
        let swapScope = try #require(PermutationQuery.build(graph: runner.graph).first)
        let swap = AnyEncoderScope.swap(swapScope)

        // The swap reaches ((1, 2), 1), which passes.
        let refused = runner.runPass(swap, boundValueFingerprint: nil)
        runner.applyPassPolicy(refused)
        #expect(refused.report.anyAccepted == false)

        // Lowering the third leaf to zero keeps the failure and leaves the swapped positions untouched.
        let outsideLeaf = try #require(runner.graph.leafNodes.max { lhs, rhs in
            runner.graph.nodes[lhs].positionRange!.lowerBound < runner.graph.nodes[rhs].positionRange!.lowerBound
        })
        let valueSearch = AnyEncoderScope.valueSearch(ValueMinimizationScope(leaves: [LeafEntry(nodeID: outsideLeaf)], batchZeroEligible: false))
        let valuePass = runner.runPass(valueSearch, boundValueFingerprint: nil)
        runner.applyPassPolicy(valuePass)
        #expect(valuePass.report.anyAccepted)

        #expect(runner.evaluateDispatch(swap) != .skip)
        let retried = runner.runPass(swap, boundValueFingerprint: nil)
        #expect(retried.report.anyAccepted)
    }

    // MARK: - Probe Cache

    @Test("A numeric admission's rejection does not turn away the same candidate under standard admission when the key records the decision", arguments: [
        ProbeCacheKeying.decision,
        .decisionAndIncumbent,
    ])
    func admissionRejectionDoesNotAnswerForStandardAdmission(_ keying: ProbeCacheKeying) throws {
        let generator = Gen.choose(in: UInt64(0) ... 10)._bound(
            forward: { controller in Gen.zip(Gen.just(controller), Gen.choose(in: UInt64(0) ... controller)) },
            backward: { $0.0 }
        )
        let tree = try #require(try Interpreters.reflect(generator, with: (UInt64(10), UInt64(10))))
        let base = ChoiceSequence(tree)
        let positions = base.indices.filter { base[$0].value != nil }
        var candidate = base
        // Exact decoding clamps the bound value 10 to the new controller's upper bound, 5.
        candidate[positions[0]] = candidate[positions[0]].withBitPattern(5)
        var context = Reducer.Context(
            incumbent: Counterexample(sequence: base, tree: tree, output: (UInt64(10), UInt64(10))),
            incumbentHash: ZobristHash.hash(of: base),
            graph: ChoiceGraph.build(from: tree),
            rejectCache: ProbeCache(keying: keying),
            decoder: ReductionDecoder(generator: generator.erase(), property: { _ in false }, probeWrapper: nil, hasBind: true),
            encoder: ValueSearchEncoder.self
        )
        let configuration = SearchConfiguration(acceptance: .stop, requiresExactDecoder: true, reportedMutation: nil)

        context.candidateBuffer = candidate
        let strict = Reducer.evaluate(.written(mutation: .leafValues([]), admission: .numericJoint([])), configuration: configuration, context: &context)
        #expect(strict.isAccepted == false)

        context.candidateBuffer = candidate
        let standard = Reducer.evaluate(.written(mutation: .leafValues([]), admission: .standard), configuration: configuration, context: &context)
        #expect(context.report.counts.rejectedByCache == 0)
        #expect(standard.isAccepted)
    }

    // MARK: - Covering Rows

    @Test("A cached covering row stream yields the rows a fresh generator for the same shape yields, whichever index is read first")
    func cachedCoveringRowsMatchFreshGenerator() {
        let domainSizes: [UInt64] = [3, 8, 5, 8]
        let cache = CoveringRowCache()
        let stream = cache.stream(forDomainSizes: domainSizes)
        #expect(cache.stream(forDomainSizes: domainSizes) === stream)

        // Reading a later row first generates every row before it.
        _ = stream.row(at: 5)
        let generator = BalancedCoveringArrayGenerator(domainSizes: domainSizes)
        var index = 0
        while let expected = generator.next() {
            #expect(stream.row(at: index)?.values == expected.values, "Row \(index) differs")
            index += 1
        }
        #expect(index > 5)
        #expect(stream.row(at: index) == nil)
    }

    // MARK: - Swap Extension

    @Test("Swap extension reaches the final slot after doubling overshoots the group")
    func swapExtensionTriesFinalSlotAfterOvershoot() throws {
        let leaf = Gen.choose(in: UInt64(0) ... 10)
        let generator = Gen.zip(leaf, leaf, leaf)
        let tree = try #require(try Interpreters.reflect(generator, with: (UInt64(3), UInt64(1), UInt64(2))))
        let base = ChoiceSequence(tree)
        let graph = ChoiceGraph.build(from: tree)
        let scope = try #require(PermutationQuery.build(graph: graph).first)
        var search = SwapSearch(scope: scope, sequence: base, graph: graph)
        var buffer = base

        _ = try #require(search.next(.initial, into: &buffer))
        #expect(buffer.compactMap { $0.value?.choice.bitPattern64 } == [1, 3, 2])
        let accepted = buffer
        _ = try #require(search.next(.accepted(recovered: accepted), into: &buffer))
        #expect(buffer.compactMap { $0.value?.choice.bitPattern64 } == [1, 2, 3])
    }

    // MARK: - Relax Round

    @Test("A committed relax round flags a graph its exploitation rebuilt without unselected branches")
    func committedRelaxRoundFlagsStrippedGraph() throws {
        let arms = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 100)),
            (1, Gen.choose(in: UInt64(200) ... 300)),
        ])
        let generator = Gen.arrayOf(arms, within: 0 ... 3)
        let start = [UInt64(10), 80]
        let tree = try #require(try Interpreters.reflect(generator, with: start))
        var tuning = ReductionTuning()
        tuning.relaxMaterializationBudget = 1
        var runner = ReductionSession(
            generator: generator,
            initialTree: tree,
            initialOutput: start,
            configuration: .init(maxStalls: 2, enabledEncoders: [.substitution, .deletion], tuning: tuning),
            collectStats: false,
            property: { $0.isEmpty }
        )

        // The substitution perturbation decodes with picks materialized; exploitation then removes an element, whose decoding leaves picks unmaterialized and rebuilds the graph from that tree.
        let committed = runner.runRelaxRound()

        #expect(committed)
        let lacksUnselectedBranches = runner.graph.nodes.contains { node in
            guard case let .pick(metadata) = node.kind else {
                return false
            }
            return UInt64(metadata.branchElements.count) < metadata.branchCount
        }
        try #require(lacksUnselectedBranches, "The fixture must leave the committed graph without unselected branches")
        #expect(runner.graphIsStripped)
    }

    // MARK: - Final Reorder

    @Test("The final reorder sorts a group under a bind as it does without one")
    func finalReorderSortsUnderBind() throws {
        let leaf = Gen.choose(in: -10 ... 10)
        let direct = Gen.zip(leaf, leaf)
        let bound = Gen.just(UInt64(0))._bound(forward: { _ in direct }, backward: { _ in UInt64(0) })
        for generator in [direct, bound] {
            let tree = try #require(try Interpreters.reflect(generator, with: (0, -1)))
            var runner = ReductionSession(
                generator: generator,
                initialTree: tree,
                initialOutput: (0, -1),
                configuration: .init(maxStalls: 1, enabledEncoders: [.numericReorder]),
                collectStats: false,
                property: { _ in false }
            )
            runner.runReorderPass()
            let value = try #require(runner.incumbent.output as? (Int, Int))
            #expect(value == (-1, 0))
        }
    }

    @Test("The final reorder sorts every independent group, not only the first it accepts")
    func finalReorderSortsEveryGroup() throws {
        let leaf = Gen.choose(in: -10 ... 10)
        let generator = Gen.zip(Gen.zip(leaf, leaf), Gen.zip(leaf, leaf))
        let start = ((0, -1), (0, -1))
        let tree = try #require(try Interpreters.reflect(generator, with: start))
        var runner = ReductionSession(
            generator: generator,
            initialTree: tree,
            initialOutput: start,
            configuration: .init(maxStalls: 1, enabledEncoders: [.numericReorder]),
            collectStats: false,
            property: { _ in false }
        )
        runner.run()
        let value = try #require(runner.incumbent.output as? ((Int, Int), (Int, Int)))
        #expect(value.0 == (-1, 0))
        #expect(value.1 == (-1, 0))
    }
}

// MARK: - Helpers

/// A single integer leaf converged at `start`, under a property whose failures now reach one step closer to zero.
struct ConfirmationCase: CustomTestStringConvertible, Sendable {
    let start: Int64
    let fails: @Sendable (Int64) -> Bool
    let testDescription: String

    init(start: Int64, failsAtOrBelow threshold: Int64) {
        self.start = start
        fails = { $0 <= threshold }
        testDescription = "\(start), failing at or below \(threshold)"
    }

    init(start: Int64, failsAtOrAbove threshold: Int64) {
        self.start = start
        fails = { $0 >= threshold }
        testDescription = "\(start), failing at or above \(threshold)"
    }
}
