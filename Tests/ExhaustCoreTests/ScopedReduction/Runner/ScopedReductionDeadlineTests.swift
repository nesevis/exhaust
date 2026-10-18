import Testing
@testable import ExhaustCore

@Suite("Scoped reduction deadlines")
struct ScopedReductionDeadlineTests {
    @Test("An expired deadline starts no search and leaves the incumbent unchanged")
    func expiryBeforeDispatch() throws {
        let clock = ReductionTestClock()
        var calls = 0
        var runner = try makeRunner(Gen.choose(in: UInt64(0) ... 100), start: 37, clock: clock, encoders: [.valueSearch]) { _ in
            calls += 1
            return false
        }
        clock.expire()

        runner.run()

        #expect(calls == 0)
        #expect(runner.stats.reductionProbes == 0)
        #expect(runner.stats.reductionWasCapped)
        #expect(runner.incumbent.output as? UInt64 == 37)
        #expect(runner.sources.isEmpty)
    }

    @Test("Expiry in the property preserves an acceptance and accounts for the in-flight probe once", arguments: [false, true], [false, true])
    func expiryDuringProperty(accepted: Bool, collectStats: Bool) throws {
        let clock = ReductionTestClock()
        var calls = 0
        var runner = try makeRunner(Gen.choose(in: UInt64(0) ... 100), start: 37, clock: clock, encoders: [.valueSearch], collectStats: collectStats) { _ in
            calls += 1
            clock.expire()
            return accepted == false
        }

        runner.run()

        #expect(calls == 1)
        #expect(runner.passCounter == 1)
        #expect(runner.stats.reductionProbes == 1)
        #expect(runner.stats.reductionProbesAccepted == (accepted ? 1 : 0))
        #expect(runner.anyAcceptanceEverOccurred == accepted)
        #expect(runner.incumbent.output as? UInt64 == (accepted ? 0 : 37))
        #expect(ChoiceSequence(runner.incumbent.tree) == runner.incumbent.sequence)
        #expect(runner.stats.reductionWasCapped)
        #expect(runner.sources.isEmpty)
        #expect(runner.stats.materializationsBySite[.decoder, default: 0] == (accepted ? 2 : 1))
    }

    @Test("A structural acceptance at the deadline rebuilds the committed graph exactly once")
    func structuralAcceptanceRebuildsBeforeFinishing() throws {
        let clock = ReductionTestClock()
        let generator = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 0 ... 5)
        var calls = 0
        var runner = try makeRunner(generator, start: [UInt64(3), 2, 1], clock: clock, encoders: [.deletion]) { _ in
            calls += 1
            clock.expire()
            return false
        }
        let initialRebuilds = runner.stats.graphStats.fullGraphRebuilds

        runner.run()

        #expect(calls == 1)
        #expect(runner.passCounter == 1)
        #expect(runner.stats.reductionProbesAccepted == 1)
        #expect(runner.stats.graphStats.fullGraphRebuilds == initialRebuilds + 1)
        #expect(runner.incumbent.output as? [UInt64] == [])
        #expect(ChoiceSequence(runner.incumbent.tree) == runner.incumbent.sequence)
        #expect(runner.graph.nodes.count == ChoiceGraph.build(from: runner.incumbent.tree).nodes.count)
        #expect(runner.stats.reductionWasCapped)
    }

    @Test("The enabled final reorder still canonicalizes the result after expiry")
    func finalReorderRunsAfterExpiry() throws {
        let clock = ReductionTestClock()
        let generator = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 3)
        var calls = 0
        var runner = try makeRunner(generator, start: [UInt64(3), 1, 2], clock: clock, encoders: [.numericReorder]) { _ in
            calls += 1
            return false
        }
        clock.expire()

        runner.run()

        #expect(calls == 1)
        #expect(runner.incumbent.output as? [UInt64] == [1, 2, 3])
        #expect(runner.stats.encoderProbesAccepted[.numericReorder] == 1)
        #expect(runner.stats.reductionWasCapped)
    }

    @Test("Post-cycle numeric searches stop after an in-flight property expires the deadline", arguments: [EncoderName.relationSearch, .stagedJointSearch], [false, true])
    func postCycleSearchHonorsExpiry(encoder: EncoderName, accepted: Bool) throws {
        let clock = ReductionTestClock()
        let generator = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 2)
        var calls = 0
        var runner = try makeRunner(generator, start: [UInt64(40), 20], clock: clock, encoders: [encoder]) { _ in
            calls += 1
            clock.expire()
            return accepted == false
        }
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
        let action: ScopedReductionRunner.PostCycleAction = encoder == .relationSearch ? .relationPass : .stagedJointPass

        _ = runner.runPostCycleActions([action])

        #expect(calls == 1)
        #expect(runner.stats.reductionProbes == 1)
        #expect(runner.stats.reductionProbesAccepted == (accepted ? 1 : 0))
        #expect(runner.deadline.isExpired)
    }
}

// MARK: - Fixtures

/// Expires on demand so deadlines are independent of test execution speed.
private final class ReductionTestClock {
    var now: UInt64 = 0

    func expire() {
        now = 10
    }
}

/// Shares one controllable deadline between dispatch and every probe.
private func makeRunner<Output>(
    _ generator: Generator<Output>,
    start: Output,
    clock: ReductionTestClock,
    encoders: Set<EncoderName>,
    collectStats: Bool = true,
    property: @escaping (Output) -> Bool
) throws -> ScopedReductionRunner {
    let tree = try #require(try Interpreters.reflect(generator, with: start))
    return ScopedReductionRunner(
        generator: generator,
        initialTree: tree,
        initialOutput: start,
        configuration: .init(maxStalls: 2, wallClockDeadlineNanoseconds: 10, enabledEncoders: encoders),
        collectStats: collectStats,
        currentNanoseconds: { clock.now },
        property: property
    )
}
