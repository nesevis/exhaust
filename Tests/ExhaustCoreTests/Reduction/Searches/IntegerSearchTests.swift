import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Integer search")
struct IntegerSearchTests {
    @Test("A search stopped at the deadline right after a stepper acceptance records the bound its rejections established, not the accepted value")
    func pendingStepperAcceptanceRecordsResumeBound() throws {
        // Values below 30 pass: the direct shot at zero and the stepper's first probe, 25, are rejected, which rules out everything below 26. The next probe, 38, is accepted, and the deadline stops the search before it learns of it.
        let run = try IntegerSearchRun(
            generator: Gen.choose(in: UInt64(0) ... 100),
            start: 50,
            fails: { $0 >= 30 },
            expires: { _ in true }
        )

        #expect(run.acceptedBitPattern == 38)
        #expect(run.recordedBound == 26)
    }

    @Test("A search stopped at the deadline during a gap scan records the scan's acceptance as the leaf's bound")
    func pendingGapScanAcceptanceReachesConvergenceRecord() throws {
        // Binary search converges at 20, leaving a gap of 20 below it, which the scan walks upward from zero until 3 fails.
        let run = try IntegerSearchRun(
            generator: Gen.choose(in: UInt64(0) ... 100),
            start: 50,
            fails: { $0 >= 20 || $0 == 3 },
            expires: { $0 < 20 }
        )

        #expect(run.acceptedBitPattern == 3)
        #expect(run.recordedBound == 3)
    }

    @Test("A search stopped at the deadline during cross-zero records the crossing value as the leaf's bound")
    func pendingCrossZeroAcceptanceReachesConvergenceRecord() throws {
        // Binary search and the gap scan settle at 20 on the positive side, and cross-zero then reaches -1.
        let run = try IntegerSearchRun(
            generator: Gen.choose(in: Int64(-100) ... 100),
            start: 50,
            fails: { $0 >= 20 || $0 == -1 },
            expires: { $0 < 0 }
        )

        #expect(run.acceptedBitPattern == Int64(-1).bitPattern64)
        #expect(run.recordedBound == run.acceptedBitPattern)
    }

    @Test("A leaf accepted at its target in the per-leaf zero round is excluded from batch bisection")
    func perLeafZeroAcceptanceConvergesLeaf() throws {
        let generator = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 1000), exactly: 5)
        let tree = try #require(try Interpreters.reflect(generator, with: [500, 500, 500, 500, 500]))
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence(tree)
        let leafNodeIDs = graph.leafNodes.sorted { lhs, rhs in
            graph.nodes[lhs].positionRange!.lowerBound < graph.nodes[rhs].positionRange!.lowerBound
        }
        let leafIndices = leafNodeIDs.map { graph.nodes[$0].positionRange!.lowerBound }
        var search = IntegerSearch(
            scope: ValueMinimizationScope(leaves: leafNodeIDs.map { LeafEntry(nodeID: $0) }, batchZeroEligible: true),
            sequence: sequence,
            graph: graph,
            warmStarts: [:],
            tuning: ReductionTuning()
        )

        // The property fails while the last four leaves are all at least 10, so only the first leaf zeroes on its own, leaving four leaves for batch bisection.
        var feedback = SearchFeedback.initial
        var buffer = sequence
        var baseline = sequence
        while search.state.phase != .batchBisect {
            _ = try #require(search.nextMaterialized(feedback, from: baseline, into: &buffer))
            let fails = leafIndices.dropFirst().allSatisfy { index in
                (buffer[index].value?.choice.bitPattern64 ?? 0) >= 10
            }
            feedback = fails ? .accepted(recovered: buffer) : .rejected(.propertyPassed)
            if fails {
                baseline = buffer
            }
        }

        let firstLeaf = try #require(search.state.leafPositions.firstIndex { $0.nodeID == leafNodeIDs[0] })
        #expect(search.state.bisection?.convergedIndices.contains(firstLeaf) == true)
        #expect(search.state.leafPositions[firstLeaf].currentBitPattern == search.state.leafPositions[firstLeaf].targetBitPattern)
    }

    @Test("After an acceptance, the next candidate builds on the recovered sequence rather than the candidate the search emitted")
    func nextCandidateBuildsOnRecoveredSequence() throws {
        var fixture = try TwoLeafSearch()
        var buffer = fixture.sequence
        _ = try #require(fixture.search.nextMaterialized(.initial, from: fixture.sequence, into: &buffer))
        _ = try #require(fixture.search.nextMaterialized(.rejected(.propertyPassed), from: fixture.sequence, into: &buffer))

        // Decoding rewrote the leaf the search does not touch.
        var recovered = buffer
        recovered[fixture.otherLeafIndex] = recovered[fixture.otherLeafIndex].withBitPattern(7)
        _ = try #require(fixture.search.nextMaterialized(.accepted(recovered: recovered), from: recovered, into: &buffer))

        #expect(buffer[fixture.otherLeafIndex].value?.choice.bitPattern64 == 7)
    }

    @Test("A recovered sequence of a different length ends the search")
    func recoveredLengthChangeEndsSearch() throws {
        var fixture = try TwoLeafSearch()
        var buffer = fixture.sequence
        _ = try #require(fixture.search.nextMaterialized(.initial, from: fixture.sequence, into: &buffer))
        // A rejected direct shot leaves the stepper with candidates, so only the length change can end the search.
        _ = try #require(fixture.search.nextMaterialized(.rejected(.propertyPassed), from: fixture.sequence, into: &buffer))
        let longer = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 3)
        let recovered = try ChoiceSequence(#require(try Interpreters.reflect(longer, with: [50, 50, 50])))

        #expect(fixture.search.nextMaterialized(.accepted(recovered: recovered), from: recovered, into: &buffer) == nil)
    }

    @Test("Integer reduction can cross zero from a negative range endpoint", arguments: [-1 ... 1, -10 ... 10])
    func integerReductionPrefersPositive(range: ClosedRange<Int>) throws {
        let generator = Gen.choose(in: range)
        let output = try reduceFromReflection(
            generator,
            startingAt: range.lowerBound,
            config: .init(maxStalls: 2, enabledEncoders: [.valueSearch])
        ) { value in
            value == 0
        }
        #expect(output == 1)
    }

    @Test("A negative integer reduces to its positive counterpart at every magnitude", arguments: [false, true])
    func integerCounterpartAtEveryMagnitude(isRangeEndpoint: Bool) throws {
        let magnitudes = Gen.choose(in: 1 ... 1_000_000) as Generator<Int>
        try exhaustCheck(magnitudes) { (magnitude: Int) throws -> Bool in
            let bound = isRangeEndpoint ? magnitude : 1_000_000
            let output = try reduceFromReflection(
                Gen.choose(in: -bound ... bound),
                startingAt: -magnitude,
                config: .init(maxStalls: 2, enabledEncoders: [.valueSearch])
            ) { value in
                abs(value) < magnitude
            }
            return output == magnitude
        }
    }
}

// MARK: - Fixture

/// Value search over a single leaf whose property fails on `fails`, with a deadline that expires once the property fails on a value satisfying `expires`, before the search is asked for another candidate and learns of the acceptance.
private struct IntegerSearchRun {
    let acceptedBitPattern: UInt64
    let recordedBound: UInt64?

    init<Value>(
        generator: Generator<Value>,
        start: Value,
        fails: @escaping (Value) -> Bool,
        expires: @escaping (Value) -> Bool
    ) throws {
        let tree = try #require(try Interpreters.reflect(generator, with: start))
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence(tree)
        let leafNodeID = try #require(graph.leafNodes.first)
        let leafIndex = try #require(graph.nodes[leafNodeID].positionRange).lowerBound
        var isExpired = false

        let result = Reducer.reduce(
            ValueSearchEncoder.reduce(
                ValueMinimizationScope(leaves: [LeafEntry(nodeID: leafNodeID)], batchZeroEligible: false),
                input: EncoderInput(baseSequence: sequence, tree: tree, graph: graph, warmStartRecords: [:], tuning: ReductionTuning())
            ),
            context: Reducer.Context(
                incumbent: Counterexample(
                    sequence: sequence,
                    tree: tree,
                    output: start
                ),
                incumbentHash: ZobristHash.hash(of: sequence),
                graph: graph,
                rejectCache: ProbeCache(),
                decoder: ReductionDecoder(
                    generator: generator.erase(),
                    property: { output in
                        let value = output as! Value
                        guard fails(value) else {
                            return true
                        }
                        if expires(value) {
                            isExpired = true
                        }
                        return false
                    },
                    probeWrapper: nil,
                    hasBind: false
                ),
                encoder: ValueSearchEncoder.self,
                deadline: ReductionDeadline(start: 0, budget: 1, clock: { isExpired ? 1 : 0 })
            )
        )

        acceptedBitPattern = try #require(result.incumbent.sequence[leafIndex].value?.choice.bitPattern64)
        recordedBound = result.report.searchReport.convergenceRecords[leafNodeID]?.bound
    }
}

/// Integer search over the first of two leaves, starting at 50 each, so the second leaf shows which baseline the search builds on.
private struct TwoLeafSearch {
    let sequence: ChoiceSequence
    let otherLeafIndex: Int
    var search: IntegerSearch

    init() throws {
        let generator = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 2)
        let tree = try #require(try Interpreters.reflect(generator, with: [50, 50]))
        let graph = ChoiceGraph.build(from: tree)
        sequence = ChoiceSequence(tree)
        let leafNodeIDs = graph.leafNodes.sorted { lhs, rhs in
            graph.nodes[lhs].positionRange!.lowerBound < graph.nodes[rhs].positionRange!.lowerBound
        }
        otherLeafIndex = try #require(graph.nodes[leafNodeIDs[1]].positionRange).lowerBound
        search = IntegerSearch(
            scope: ValueMinimizationScope(leaves: [LeafEntry(nodeID: leafNodeIDs[0])], batchZeroEligible: false),
            sequence: sequence,
            graph: graph,
            warmStarts: [:],
            tuning: ReductionTuning()
        )
    }
}
