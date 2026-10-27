import Testing
@testable import ExhaustCore

@Suite("Post-cycle recovery regressions")
struct PostCycleRecoveryTests {
    @Test("Convergence confirmation crosses a two-step gap after binary search")
    func confirmationCrossesTwoStepGap() throws {
        let generator = Gen.choose(in: UInt64(0) ... 200)
        let tree = try #require(try Interpreters.reflect(generator, with: UInt64(100)))
        var runner = ReductionSession(
            generator: generator,
            initialTree: tree,
            initialOutput: UInt64(100),
            configuration: .init(maxStalls: 2, enabledEncoders: [.valueSearch, .convergenceConfirmation]),
            collectStats: true,
            property: { $0 < 100 && $0 != 98 }
        )
        runner.run()
        #expect(runner.incumbent.output as? UInt64 == 98)
    }

    @Test("A cached rejected neighbor must not suppress the second confirmation probe", arguments: [false, true])
    func cachedNeighborPreservesGapProbe(cached: Bool) throws {
        let generator = Gen.choose(in: UInt64(0) ... 100)
        let tree = try #require(try Interpreters.reflect(generator, with: UInt64(50)))
        var calls: [UInt64] = []
        var runner = ReductionSession(
            generator: generator,
            initialTree: tree,
            initialOutput: UInt64(50),
            configuration: .init(maxStalls: 2),
            collectStats: false,
            property: { value in
                calls.append(value)
                return value != 50 && value != 48
            }
        )
        let leaf = try #require(runner.graph.leafNodes.first)
        runner.graph.convergenceStore[leaf] = ConvergedOrigin(
            bound: 50,
            signal: .monotoneConvergence,
            configuration: .binarySearchSemanticSimplest,
            cycle: 0
        )
        if cached {
            var candidate = runner.incumbent.sequence
            candidate[0] = candidate[0].withBitPattern(49)
            let lookup = runner.rejectCache.lookup(
                probeHash: ZobristHash.hash(of: candidate),
                decision: ProbeDecision(isGuided: false),
                incumbentHash: runner.incumbentHash
            )
            runner.rejectCache.record(
                lookup,
                outcome: .propertyPassed(materializationAttempts: 1, sources: .unknown)
            )
        }
        runner.stallBudget = 0
        _ = runner.runPostCycleActions([.confirmConvergence])
        #expect(runner.incumbent.output as? UInt64 == 48)
        #expect(runner.stallBudget == 2)
        #expect(runner.stats.reductionProbesAccepted == 1)
        #expect(runner.stats.reductionProbes == 2)
        #expect(runner.stats.reductionProbesRejectedByCache == (cached ? 1 : 0))
        #expect(calls == (cached ? [48] : [49, 48]))
        #expect(calls.contains(48))
        #expect(runner.graph.convergenceStore[leaf] == nil)
    }

    @Test("A post-cycle relation improvement restores the stall budget")
    func relationRestoresStallBudget() throws {
        let leaf = Gen.choose(in: UInt64(0) ... 100)
        let generator = Gen.zip(leaf, leaf)
        let start = (UInt64(6), UInt64(9))
        let tree = try #require(try Interpreters.reflect(generator, with: start))
        var runner = ReductionSession(
            generator: generator,
            initialTree: tree,
            initialOutput: start,
            configuration: .init(maxStalls: 1, enabledEncoders: [.relationSearch]),
            collectStats: false,
            property: { value in value.0 == 0 || value.0 * 3 != value.1 * 2 }
        )
        for nodeID in runner.graph.leafNodes {
            guard case let .chooseBits(metadata) = runner.graph.nodes[nodeID].kind else {
                continue
            }
            runner.graph.convergenceStore[nodeID] = ConvergedOrigin(
                bound: metadata.value.bitPattern64,
                signal: .monotoneConvergence,
                configuration: .binarySearchSemanticSimplest,
                cycle: 0
            )
        }
        runner.stallBudget = 0
        #expect(runner.runPostCycleActions([.relationPass]) == .completed)
        let output = try #require(runner.incumbent.output as? (UInt64, UInt64))
        #expect(output == (2, 3))
        #expect(runner.anyAccepted)
        #expect(runner.stallBudget == 1)
        #expect(runner.graph.leafNodes.allSatisfy { runner.graph.convergenceStore[$0] == nil })
    }

    @Test("Relation progress is followed by another value-search cycle", arguments: [1, 2, 3])
    func relationProgressGetsValueSearch(maxStalls: Int) throws {
        let leaf = Gen.choose(in: UInt64(0) ... 100)
        let generator = Gen.zip(leaf, leaf, leaf)
        let start = (UInt64(6), UInt64(9), UInt64(7))
        let tree = try #require(try Interpreters.reflect(generator, with: start))
        var runner = ReductionSession(
            generator: generator,
            initialTree: tree,
            initialOutput: start,
            configuration: .init(
                maxStalls: maxStalls,
                enabledEncoders: [.valueSearch, .relationSearch, .convergenceConfirmation]
            ),
            collectStats: true,
            property: { value in value.0 == 0 || value.0 * 3 != value.1 * 2 || value.2 < value.0 + 1 }
        )
        runner.run()
        let output = try #require(runner.incumbent.output as? (UInt64, UInt64, UInt64))
        #expect(output == (2, 3, 3))
    }

    @Test(
        "Rejected confirmation preserves the checkpoint and does not renew the stall budget",
        arguments: [UInt64(0), 1, 50]
    )
    func rejectedConfirmationDoesNotRestart(start: UInt64) throws {
        let generator = Gen.choose(in: UInt64(0) ... 100)
        let tree = try #require(try Interpreters.reflect(generator, with: start))
        var calls: [UInt64] = []
        var runner = ReductionSession(
            generator: generator,
            initialTree: tree,
            initialOutput: start,
            configuration: .init(maxStalls: 2),
            collectStats: false,
            property: { value in
                calls.append(value)
                return value != start
            }
        )
        let leaf = try #require(runner.graph.leafNodes.first)
        runner.graph.convergenceStore[leaf] = ConvergedOrigin(
            bound: start,
            signal: .monotoneConvergence,
            configuration: .binarySearchSemanticSimplest,
            cycle: 0
        )
        runner.stallBudget = 0

        #expect(runner.runPostCycleActions([.confirmConvergence]) == .completed)
        // Repeating confirmation must reuse its rejected probes, including the second step.
        #expect(runner.runPostCycleActions([.confirmConvergence]) == .completed)

        #expect(calls == (start == 0 ? [] : start == 1 ? [0] : [49, 48]))
        #expect(runner.incumbent.output as? UInt64 == start)
        #expect(runner.incumbent.sequence == ChoiceSequence(tree))
        #expect(runner.stallBudget == 0)
        #expect(runner.anyAccepted == false)
        #expect(runner.graph.convergenceStore[leaf]?.bound == start)
    }

    @Test("Confirmation adopts an in-flight witness before checking the next action deadline", arguments: [false, true])
    func confirmationAdoptsBeforeDeadline(expires: Bool) throws {
        let generator = Gen.choose(in: UInt64(0) ... 100)
        let tree = try #require(try Interpreters.reflect(generator, with: UInt64(50)))
        var now: UInt64 = 0
        var calls: [UInt64] = []
        var runner = ReductionSession(
            generator: generator,
            initialTree: tree,
            initialOutput: UInt64(50),
            configuration: .init(maxStalls: 2, wallClockDeadlineNanoseconds: 10),
            collectStats: false,
            currentNanoseconds: { now },
            property: { value in
                calls.append(value)
                now = expires ? 10 : 0
                return false
            }
        )
        let leaf = try #require(runner.graph.leafNodes.first)
        runner.graph.convergenceStore[leaf] = ConvergedOrigin(
            bound: 50,
            signal: .monotoneConvergence,
            configuration: .binarySearchSemanticSimplest,
            cycle: 0
        )
        runner.stallBudget = 0

        let outcome = runner.runPostCycleActions([.confirmConvergence, .confirmConvergence])
        #expect(outcome == (expires ? .deadline : .completed))

        #expect(calls == [49])
        #expect(runner.incumbent.output as? UInt64 == 49)
        #expect(runner.incumbent.sequence == ChoiceSequence(runner.incumbent.tree))
        #expect(runner.incumbentHash == ZobristHash.hash(of: runner.incumbent.sequence))
        #expect(runner.stallBudget == 2)
        #expect(runner.anyAcceptanceEverOccurred)
        #expect(runner.stats.reductionProbesAccepted == 1)
        #expect(runner.graph.leafNodes.allSatisfy { runner.graph.convergenceStore[$0] == nil })
        #expect(runner.deadline.isExpired == expires)
    }

    @Test("Guided confirmation rebuilds a shortened bound tree and retains compatible floors")
    func confirmationRebuildsReshapedGraph() throws {
        let generator = Gen.choose(in: UInt64(0) ... 4)._bound(
            forward: { count in Gen.arrayOf(Gen.choose(in: UInt64(0) ... 10), exactly: count) },
            backward: { UInt64($0.count) }
        )
        let start: [UInt64] = [5, 5, 5]
        let tree = try #require(try Interpreters.reflect(generator, with: start))
        var runner = ReductionSession(
            generator: generator,
            initialTree: tree,
            initialOutput: start,
            configuration: .init(maxStalls: 1),
            collectStats: false,
            property: { $0.isEmpty }
        )
        for nodeID in runner.graph.leafNodes {
            guard case let .chooseBits(metadata) = runner.graph.nodes[nodeID].kind else {
                continue
            }
            runner.graph.convergenceStore[nodeID] = ConvergedOrigin(
                bound: metadata.value.bitPattern64,
                signal: .monotoneConvergence,
                configuration: .binarySearchSemanticSimplest,
                cycle: 0
            )
        }
        let previousNodeCount = runner.graph.nodes.count
        runner.stallBudget = 0

        _ = runner.runPostCycleActions([.confirmConvergence])

        #expect(runner.incumbent.output as? [UInt64] == [5, 5])
        #expect(runner.incumbent.sequence == ChoiceSequence(runner.incumbent.tree))
        #expect(runner.incumbentHash == ZobristHash.hash(of: runner.incumbent.sequence))
        #expect(runner.incumbent.sequence.shortLexPrecedes(ChoiceSequence(tree)))
        #expect(runner.graph.nodes.count < previousNodeCount)
        let rebuilt = ChoiceGraph.build(from: runner.incumbent.tree)
        #expect(runner.graph.leafNodes.map { runner.graph.nodes[$0].positionRange } == rebuilt.leafNodes
            .map { rebuilt.nodes[$0].positionRange })
        #expect(runner.graphIsStripped)
        let floors = runner.graph.leafNodes.map { runner.graph.convergenceStore[$0]?.bound }
        #expect(floors == [nil, 5, 5])
        #expect(runner.stallBudget == 1)
        #expect(runner.stats.reductionProbesAccepted == 1)
    }
}
