import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Final reorder diagnostics")
struct ReorderFinalizationTests {
    @Test("Stall diagnostics include final reorder acceptance without rebuilding the graph", arguments: [false, true], [false, true])
    func finalReorderAcceptanceIsIncluded(accepted: Bool, expiresDuringProperty: Bool) throws {
        let generator = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 3 ... 3)
        let output = [UInt64(3), 2, 1]
        let tree = try #require(try Interpreters.reflect(generator, with: output))
        let clock = ReorderTestClock()
        var propertyCalls = 0
        var machine = ReductionMachine(
            gen: generator,
            initialTree: tree,
            initialOutput: output,
            config: .init(maxStalls: 2, wallClockDeadlineNanoseconds: 100, enabledEncoders: [.numericReorder]),
            collectStats: true,
            currentNanoseconds: clock.read,
            property: { _ in
                propertyCalls += 1
                if expiresDuringProperty {
                    clock.expire()
                }
                return accepted == false
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
        let initialRebuilds = machine.stats.graphStats.fullGraphRebuilds
        machine.phase = .reorderPass
        finishReorder(&machine)

        #expect(try machine.next() == nil)
        #expect(propertyCalls == 1)
        #expect(machine.output as? [UInt64] == (accepted ? [1, 2, 3] : output))
        #expect(machine.anyAcceptanceEverOccurred == accepted)
        #expect(machine.stats.anyAcceptanceEverOccurred == accepted)
        #expect(machine.stats.encoderProbesAccepted[.numericReorder] == (accepted ? 1 : 0))
        #expect(machine.stats.stalledLeafCount == 3)
        #expect(machine.stats.stalledLeafResidualDistance == 6)
        #expect(machine.stats.graphStats.fullGraphRebuilds == initialRebuilds)
        #expect(machine.stats.reductionWasCapped == expiresDuringProperty)
    }

    @Test("An expired search still runs the enabled final reorder", arguments: [
        ReorderStartPhase.beginCycle,
        .dispatching,
        .postCycle,
        .reorderPass,
    ], [false, true])
    private func expiredSearchRunsFinalReorder(phase: ReorderStartPhase, reorderEnabled: Bool) throws {
        let generator = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 3 ... 3)
        let output = [UInt64(3), 2, 1]
        let tree = try #require(try Interpreters.reflect(generator, with: output))
        let clock = ReorderTestClock()
        var propertyCalls = 0
        var machine = ReductionMachine(
            gen: generator,
            initialTree: tree,
            initialOutput: output,
            config: .init(maxStalls: 2, wallClockDeadlineNanoseconds: 100, enabledEncoders: reorderEnabled ? [.numericReorder] : []),
            collectStats: true,
            currentNanoseconds: clock.read,
            property: { _ in
                propertyCalls += 1
                return false
            }
        )
        let initialRebuilds = machine.stats.graphStats.fullGraphRebuilds
        machine.phase = phase.machinePhase
        clock.expire()
        _ = machine.next()

        #expect(try machine.next() == nil)
        #expect(propertyCalls == (reorderEnabled ? 1 : 0))
        #expect(machine.output as? [UInt64] == (reorderEnabled ? [1, 2, 3] : output))
        #expect(machine.stats.encoderProbes[.numericReorder, default: 0] == (reorderEnabled ? 1 : 0))
        #expect(machine.stats.reductionWasCapped)
        #expect(machine.stats.graphStats.fullGraphRebuilds == initialRebuilds)
        #expect(machine.stats.anyAcceptanceEverOccurred == reorderEnabled)
        #expect(machine.activeSession == nil)
        #expect(machine.pendingReport == nil)
        #expect(machine.sources.isEmpty)
    }

    @Test("Final reordering continues after a rejected property expires")
    func finalReorderContinuesAfterExpiry() throws {
        let elementGenerator = Gen.choose(in: UInt64(0) ... 100)
        let generator = Gen.zip(
            Gen.arrayOf(elementGenerator, within: 3 ... 3),
            Gen.arrayOf(elementGenerator, within: 3 ... 3)
        )
        let output = ([UInt64(3), 2, 1], [UInt64(6), 5, 4])
        let tree = try #require(try Interpreters.reflect(generator, with: output))
        let clock = ReorderTestClock()
        var propertyCalls = 0
        var machine = ReductionMachine(
            gen: generator,
            initialTree: tree,
            initialOutput: output,
            config: .init(maxStalls: 2, wallClockDeadlineNanoseconds: 100, enabledEncoders: [.numericReorder]),
            collectStats: true,
            currentNanoseconds: clock.read,
            property: { _ in
                propertyCalls += 1
                clock.expire()
                return propertyCalls == 1
            }
        )
        let initialRebuilds = machine.stats.graphStats.fullGraphRebuilds
        machine.phase = .reorderPass
        finishReorder(&machine)
        let reordered = try #require(machine.output as? ([UInt64], [UInt64]))

        #expect(reordered.0 == [1, 2, 3])
        #expect(reordered.1 == [6, 5, 4])
        #expect(propertyCalls == 2)
        #expect(machine.passCounter == 1)
        #expect(machine.stats.encoderProbes[.numericReorder] == 2)
        #expect(machine.stats.encoderProbesAccepted[.numericReorder] == 1)
        #expect(machine.stats.reductionWasCapped)
        #expect(machine.stats.graphStats.fullGraphRebuilds == initialRebuilds)
        #expect(try machine.next() == nil)
    }

    @Test("An interrupted structural acceptance is finalized once before numeric reordering")
    func interruptedStructuralAcceptancePrecedesReorder() throws {
        let generator = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 2 ... 3)
        let output = [UInt64(3), 2, 1]
        let tree = try #require(try Interpreters.reflect(generator, with: output))
        let clock = ReorderTestClock()
        var propertyCalls = 0
        var machine = ReductionMachine(
            gen: generator,
            initialTree: tree,
            initialOutput: output,
            config: .init(maxStalls: 2, wallClockDeadlineNanoseconds: 100, enabledEncoders: [.deletion, .numericReorder]),
            collectStats: true,
            currentNanoseconds: clock.read,
            property: { _ in
                propertyCalls += 1
                return false
            }
        )
        let initialRebuilds = machine.stats.graphStats.fullGraphRebuilds
        var acceptedDeletion = false
        for _ in 0 ..< 100 {
            if case .decoded(.deletion, accepted: true) = machine.next() {
                acceptedDeletion = true
                break
            }
        }
        let survivors = try #require(machine.output as? [UInt64])
        #expect(acceptedDeletion)
        #expect(survivors.count == 2)
        #expect(survivors != survivors.sorted())
        clock.expire()
        _ = machine.next()

        #expect(machine.output as? [UInt64] == survivors.sorted())
        #expect(propertyCalls == 2)
        #expect(machine.passCounter == 2)
        #expect(machine.stats.encoderProbesAccepted[.deletion] == 1)
        #expect(machine.stats.encoderProbesAccepted[.numericReorder] == 1)
        #expect(machine.stats.graphStats.fullGraphRebuilds == initialRebuilds + 1)
        #expect(machine.activeSession == nil)
        #expect(machine.pendingReport == nil)
        #expect(try machine.next() == nil)
    }
}

/// Describes session-free starting phases without sharing a mutable post-cycle frame between test cases.
private enum ReorderStartPhase: Sendable {
    case beginCycle
    case dispatching
    case postCycle
    case reorderPass

    var machinePhase: ReductionMachine.Phase {
        switch self {
            case .beginCycle:
                .beginCycle
            case .dispatching:
                .dispatching
            case .postCycle:
                .postCycle(remaining: [.confirmConvergence, .excursion])
            case .reorderPass:
                .reorderPass
        }
    }
}

/// Lets the property expire the budget after reordering starts, independently of wall-clock timing.
private final class ReorderTestClock {
    private var nanoseconds: UInt64 = 0

    func read() -> UInt64 {
        nanoseconds
    }

    func expire() {
        nanoseconds = 100
    }
}

/// Drives the cooperative final pass to completion before checking its existing finalization contract.
private func finishReorder(_ machine: inout ReductionMachine) {
    for _ in 0 ..< 10000 {
        guard machine.next() != nil else {
            return
        }
    }
    Issue.record("Final reorder did not terminate")
}
