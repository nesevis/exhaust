import Testing
@testable import ExhaustCore

@Suite("Dispatch loop policy")
struct DispatchLoopPolicyTests {
    @Test("An expired exploitation pass reports once and leaves final reorder to its host", arguments: [false, true])
    func exploitationDeadline(accepted: Bool) throws {
        let generator = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 2 ... 3)
        let initial = [UInt64(3), 2, 1]
        let tree = try #require(try Interpreters.reflect(generator, with: initial))
        var nanoseconds: UInt64 = 0
        var propertyCalls = 0
        var machine = ReductionMachine(
            gen: generator,
            initialTree: tree,
            initialOutput: initial,
            config: .init(maxStalls: 1, wallClockDeadlineNanoseconds: 100, enabledEncoders: [.deletion, .numericReorder]),
            collectStats: true,
            currentNanoseconds: { nanoseconds },
            property: { _ in
                propertyCalls += 1
                nanoseconds = 100
                return accepted == false
            }
        )
        machine.graphIsStripped = true
        let initialRebuilds = machine.stats.graphStats.fullGraphRebuilds
        var loop = DispatchLoop(policy: .exploitation)
        loop.sources = CandidateSourceBuilder.buildSources(from: machine.graph)
        var finished = false
        for _ in 0 ..< 10000 {
            let transition = loop.step(state: &machine)
            if transition == nil {
                finished = true
                break
            }
        }
        #expect(finished)
        #expect(propertyCalls == 1)
        #expect(machine.passCounter == 1)
        #expect(machine.anyAcceptanceEverOccurred == accepted)
        #expect(machine.stats.encoderProbesAccepted[.deletion] == (accepted ? 1 : 0))
        #expect(machine.stats.encoderProbes[.numericReorder] == nil)
        #expect(machine.stats.graphStats.fullGraphRebuilds == initialRebuilds + (accepted ? 1 : 0))
        #expect(machine.graphIsStripped)
        #expect(loop.activeSession == nil)
        #expect(loop.pendingReport == nil)
        #expect(loop.sources.isEmpty)
        #expect(loop.step(state: &machine) == nil)
        #expect(loop.step(state: &machine) == nil)
        #expect(machine.passCounter == 1)
    }

    @Test("Exploitation can revisit scopes rejected by ordinary dispatch", arguments: [DispatchPolicy.main, .exploitation])
    func scopeRejectionsRespectPolicy(policy: DispatchPolicy) throws {
        let generator = Gen.arrayOf(Gen.choose(in: 0 ... 100), within: 0 ... 5)
        let initial = [10, 20, 30]
        let tree = try #require(try Interpreters.reflect(generator, with: initial))
        var machine = ReductionMachine(
            gen: generator,
            initialTree: tree,
            initialOutput: initial,
            config: .init(maxStalls: 1, enabledEncoders: [.deletion]),
            collectStats: true,
            property: { _ in false }
        )
        var cachedSources = CandidateSourceBuilder.buildSources(from: machine.graph)
        for sourceIndex in cachedSources.indices {
            while let transformation = cachedSources[sourceIndex].next() {
                machine.scopeRejectionCache.recordRejection(
                    operation: transformation.operation,
                    sequence: machine.sequence,
                    graph: machine.graph
                )
            }
        }
        var loop = DispatchLoop(policy: policy)
        loop.sources = CandidateSourceBuilder.buildSources(from: machine.graph)
        var finished = false
        for _ in 0 ..< 10000 {
            if loop.step(state: &machine) == nil {
                finished = true
                break
            }
            if policy == .main, case .endCycle = machine.phase {
                finished = true
                break
            }
        }
        #expect(finished)
        #expect(loop.activeSession == nil)
        #expect(loop.pendingReport == nil)
        #expect(machine.output as? [Int] == (policy == .main ? initial : []))
        #expect(machine.anyAcceptanceEverOccurred == (policy == .exploitation))
        if policy == .exploitation {
            guard case .beginCycle = machine.phase else {
                Issue.record("An exploitation loop must not advance the main machine's cycle phase")
                return
            }
        }
    }
}
