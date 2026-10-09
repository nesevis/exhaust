import Testing
@testable import ExhaustCore

@Suite("Post-cycle frame finalization")
struct PostCycleFrameTests {
    @Test("Synchronous staged search preserves its caller's phase and skips final reorder even when a property expires", arguments: [false, true], [false, true])
    func synchronousContinuation(acceptsProbe: Bool, expiresDuringProperty: Bool) throws {
        let clock = PostCycleFrameClock()
        let generator = Gen.eachOf(Array(repeating: Gen.choose(in: 1 ... 1000), count: 2))
        let initial = [75, 100]
        let tree = try #require(try Interpreters.reflect(generator, with: initial))
        var propertyCalls = 0
        var machine = ReductionMachine(
            gen: generator,
            initialTree: tree,
            initialOutput: initial,
            config: .init(
                maxStalls: 1,
                wallClockDeadlineNanoseconds: 100,
                enabledEncoders: [.stagedJointSearch, .numericReorder],
                tuning: .init(stagedJointProbeBudget: 1)
            ),
            collectStats: true,
            currentNanoseconds: clock.read,
            property: { _ in
                propertyCalls += 1
                if expiresDuringProperty {
                    clock.expire()
                }
                return acceptsProbe == false
            }
        )
        for nodeID in machine.graph.leafNodes {
            guard case let .chooseBits(metadata) = machine.graph.nodes[nodeID].kind else {
                continue
            }
            machine.graph.convergenceStore[nodeID] = ConvergedOrigin(
                bound: metadata.value.bitPattern64,
                signal: .monotoneConvergence,
                configuration: .binarySearchSemanticSimplest,
                cycle: 0
            )
        }
        machine.convergence.deferBindInner = false
        machine.phase = .postCycle(remaining: [.releaseDeferral])
        let accepted = machine.runStagedJointSearch()
        #expect(accepted == acceptsProbe)
        #expect(machine.output as? [Int] == (acceptsProbe ? [3, 4] : initial))
        #expect(propertyCalls == 1)
        #expect(machine.passCounter == 1)
        #expect(machine.stats.encoderProbes[.stagedJointSearch] == 1)
        #expect(machine.stats.encoderProbes[.numericReorder] == nil)
        #expect(machine.dispatchLoop.activeSession == nil)
        #expect(machine.dispatchLoop.pendingReport == nil)
        #expect(machine.deferralReleasedThisCycle == false)
        guard case .postCycle(remaining: [.releaseDeferral]) = machine.phase else {
            Issue.record("Synchronous staged search must restore the caller's continuation")
            return
        }
    }

    @Test("Expiry reports a post-cycle session once, skips remaining actions, and restores reorder rejections", arguments: [
        EncoderName.relationSearch, .stagedJointSearch, .numericReorder,
    ], [(false, false), (false, true), (true, false), (true, true)])
    func deadlineBeforeDecode(encoder: EncoderName, boundary: (probeEncoded: Bool, acceptsReorder: Bool)) throws {
        let (probeEncoded, acceptsReorder) = boundary
        let clock = PostCycleFrameClock()
        let generator = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 3 ... 3)
        let initial = [UInt64(40), 20, 30]
        let tree = try #require(try Interpreters.reflect(generator, with: initial))
        var propertyCalls = 0
        var machine = ReductionMachine(
            gen: generator,
            initialTree: tree,
            initialOutput: initial,
            config: .init(maxStalls: 1, wallClockDeadlineNanoseconds: 100, enabledEncoders: [encoder]),
            collectStats: true,
            currentNanoseconds: clock.read,
            property: { _ in
                propertyCalls += 1
                return acceptsReorder == false
            }
        )
        for nodeID in machine.graph.leafNodes {
            guard case let .chooseBits(metadata) = machine.graph.nodes[nodeID].kind else {
                continue
            }
            machine.graph.convergenceStore[nodeID] = ConvergedOrigin(
                bound: metadata.value.bitPattern64,
                signal: .monotoneConvergence,
                configuration: .binarySearchSemanticSimplest,
                cycle: 0
            )
        }
        machine.convergence.deferBindInner = false
        machine.rejectCache = [0xFEED]
        switch encoder {
            case .relationSearch:
                machine.phase = .postCycle(remaining: [.relationPass, .releaseDeferral])
            case .stagedJointSearch:
                machine.phase = .postCycle(remaining: [.stagedJointPass, .releaseDeferral])
            default:
                machine.phase = .reorderPass
        }
        let initialRebuilds = machine.stats.graphStats.fullGraphRebuilds
        guard case .postCycleStarted = machine.next() else {
            Issue.record("The post-cycle pass must start before expiry")
            return
        }
        if probeEncoded {
            guard case .postCycleEncoded(_, _, cacheHit: false) = machine.next() else {
                Issue.record("The post-cycle frame must retain an undecoded probe")
                return
            }
        }
        #expect(propertyCalls == 0)
        #expect(machine.dispatchLoop.activeSession == nil)
        #expect(machine.dispatchLoop.pendingReport == nil)
        clock.expire()
        guard case .terminated = machine.next() else {
            Issue.record("Expiry must finalize the frame and terminate the machine")
            return
        }
        let reorderRuns = encoder == .numericReorder
        let accepted = reorderRuns && acceptsReorder
        let expectedProbes = reorderRuns || probeEncoded ? 1 : 0
        #expect(propertyCalls == (reorderRuns ? 1 : 0))
        #expect(machine.output as? [UInt64] == (accepted ? initial.sorted() : initial))
        #expect(ChoiceSequence(machine.tree) == machine.sequence)
        #expect(machine.passCounter == 1)
        #expect(machine.stats.encoderProbes[encoder] == expectedProbes)
        #expect(machine.stats.encoderProbesAccepted[encoder] == (accepted ? 1 : 0))
        #expect(machine.stats.graphStats.fullGraphRebuilds == initialRebuilds)
        #expect(machine.stats.reductionWasCapped)
        #expect(machine.deferralReleasedThisCycle == false)
        #expect(machine.rejectCache == [0xFEED])
        #expect(machine.dispatchLoop.activeSession == nil)
        #expect(machine.dispatchLoop.pendingReport == nil)
        #expect(machine.sources.isEmpty)
        for _ in 0 ..< 3 {
            #expect(machine.next() == nil)
        }
        #expect(machine.passCounter == 1)
        #expect(propertyCalls == (reorderRuns ? 1 : 0))
    }
}

/// Expires the search at an externally selected continuation boundary without relying on elapsed wall time.
private final class PostCycleFrameClock {
    private var nanoseconds: UInt64 = 0

    func read() -> UInt64 {
        nanoseconds
    }

    func expire() {
        nanoseconds = 100
    }
}
