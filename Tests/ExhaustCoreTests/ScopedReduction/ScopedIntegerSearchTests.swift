import Testing
@testable import ExhaustCore

@Suite("Scoped integer search")
struct ScopedIntegerSearchTests {
    @Test("A search stopped at the deadline right after a stepper acceptance records the accepted value as the leaf's bound")
    func pendingStepperAcceptanceReachesConvergenceRecord() throws {
        // Values below 10 pass, so the direct shot at zero is rejected and the stepper runs.
        let run = try IntegerSearchRun(
            generator: Gen.choose(in: UInt64(0) ... 100),
            start: 50,
            fails: { $0 >= 10 },
            expires: { _ in true }
        )

        #expect(run.acceptedBitPattern < 50)
        #expect(run.recordedBound == run.acceptedBitPattern)
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
}

// MARK: - Fixture

/// Value search over a single leaf whose property fails on `fails`, with a deadline that expires once the property fails on a value satisfying `expires`, before the search is pulled again to learn of the acceptance.
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

        let result = ScopedReductionInterpreter.run(
            ScopedValueSearchEncoder(tuning: ScopedReductionTuning()).reducer(
                ValueMinimizationScope(leaves: [LeafEntry(nodeID: leafNodeID)], batchZeroEligible: false),
                input: ScopedEncoderInput(baseSequence: sequence, tree: tree, graph: graph, warmStartRecords: [:])
            ),
            context: ScopedReductionInterpreter.Context(
                incumbent: ScopedCounterexample(
                    sequence: sequence,
                    tree: tree,
                    output: ScopedOutputHandle(value: start)
                ),
                graph: graph,
                rejectCache: [],
                decoder: ScopedDecoder(
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
                encoderName: .valueSearch,
                deadlineCheck: { isExpired }
            )
        )

        acceptedBitPattern = try #require(result.incumbent.sequence[leafIndex].value?.choice.bitPattern64)
        recordedBound = result.report.searchReport.convergenceRecords[leafNodeID]?.bound
    }
}
