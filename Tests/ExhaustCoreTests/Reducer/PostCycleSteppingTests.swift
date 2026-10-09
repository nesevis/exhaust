import Testing
@testable import ExhaustCore

@Suite("Post-cycle cooperative stepping")
struct PostCycleSteppingTests {
    @Test("Post-cycle sessions yield between encoding and decoding and retain their timing bucket", arguments: [
        EncoderName.relationSearch, .stagedJointSearch, .numericReorder,
    ])
    func yieldsAndAttributesTime(encoder: EncoderName) throws {
        let generator = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 3 ... 3)
        let initial = [UInt64(40), 20, 30]
        let tree = try #require(try Interpreters.reflect(generator, with: initial))
        var propertyCalls = 0
        var tuning = SchedulerTuning()
        tuning.stagedJointProbeBudget = 8
        var machine = ReductionMachine(
            gen: generator,
            initialTree: tree,
            initialOutput: initial,
            config: .init(maxStalls: 1, enabledEncoders: [encoder], tuning: tuning),
            collectStats: true,
            property: { _ in
                propertyCalls += 1
                return true
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
        var timings = ReductionStats.StepTimings()
        let started = try nextTransition(&machine)
        guard case .postCycleStarted = started else {
            Issue.record("A post-cycle pass must start without decoding a probe")
            return
        }
        timings.record(started, elapsed: 7)
        #expect(propertyCalls == 0)
        let encoded = try nextTransition(&machine)
        guard case let .postCycleEncoded(_, emittedEncoder, cacheHit) = encoded else {
            Issue.record("A post-cycle pass must yield after encoding")
            return
        }
        timings.record(encoded, elapsed: 7)
        #expect(emittedEncoder == encoder)
        #expect(cacheHit == false)
        guard case let .postCycleProbing(frame) = machine.phase else {
            Issue.record("A post-cycle pass must retain its own session")
            return
        }
        #expect(frame.session.phase == .decode)
        #expect(machine.dispatchLoop.activeSession == nil)
        #expect(machine.dispatchLoop.pendingReport == nil)
        #expect(propertyCalls == 0)
        let decoded = try nextTransition(&machine)
        guard case let .postCycleDecoded(_, decodedEncoder, accepted) = decoded else {
            Issue.record("A post-cycle pass must decode on a separate step")
            return
        }
        timings.record(decoded, elapsed: 7)
        #expect(decodedEncoder == encoder)
        #expect(accepted == false)
        #expect(propertyCalls == 1)

        var steps = 3
        var completed = false
        for _ in 0 ..< 10000 {
            let transition = try nextTransition(&machine)
            #expect(machine.dispatchLoop.activeSession == nil)
            #expect(machine.dispatchLoop.pendingReport == nil)
            steps += 1
            timings.record(transition, elapsed: 7)
            switch transition {
                case .relationPassCompleted, .stagedJointPassCompleted, .reorderCompleted:
                    completed = true
                default:
                    break
            }
            if completed {
                break
            }
        }
        #expect(completed)
        #expect(machine.activeSession == nil)
        if encoder == .numericReorder {
            #expect(machine.rejectCache == [0xFEED])
        } else {
            #expect(machine.rejectCache.contains(0xFEED))
            #expect(machine.rejectCache.count > 1)
        }
        #expect(machine.stats.graphStats.fullGraphRebuilds == initialRebuilds)
        #expect(timings.dispatch == 0)
        #expect(timings.passApply == 0)
        #expect(timings.encode == 0)
        #expect(timings.decode == 0)
        let ownedTime: UInt64 = switch encoder {
            case .relationSearch: timings.relationPass
            case .stagedJointSearch: timings.stagedJointPass
            default: timings.reorder
        }
        #expect(ownedTime == UInt64(steps) * 7)
        #expect(timings.relationPass + timings.stagedJointPass + timings.reorder == ownedTime)
        if encoder != .numericReorder {
            guard case .postCycle(remaining: [.releaseDeferral]) = machine.phase else {
                Issue.record("The next action must wait until the session has finished")
                return
            }
        }
    }
}

/// Evaluates the mutating step before passing its result to the testing macro.
private func nextTransition(_ machine: inout ReductionMachine) throws -> ReductionMachine.Transition {
    let transition = machine.next()
    return try #require(transition)
}
