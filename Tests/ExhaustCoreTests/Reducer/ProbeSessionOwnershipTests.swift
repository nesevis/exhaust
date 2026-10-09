import Testing
@testable import ExhaustCore

/// Pins session identity and reusable candidate storage while a post-cycle pass yields between probes.
@Suite("Probe session ownership")
struct ProbeSessionOwnershipTests {
    @Test("Cooperative staged search retains its session and candidate buffer", arguments: [2, 3, 4])
    func cooperativeStorage(leafCount: Int) throws {
        let values = Array([UInt64(75), 100, 125, 175].prefix(leafCount))
        let generator = Gen.eachOf(Array(repeating: Gen.choose(in: UInt64(0) ... 1000), count: leafCount))
        let tree = try #require(try Interpreters.reflect(generator, with: values))
        let addresses = SendableBox<[UInt]>([])
        var tuning = SchedulerTuning()
        tuning.stagedJointProbeBudget = 128
        tuning.threeWayNumericWorkLimit = 0
        var machine = ReductionMachine(
            gen: generator,
            initialTree: tree,
            initialOutput: values,
            config: .init(
                maxStalls: 1,
                enabledEncoders: [.stagedJointSearch],
                tuning: tuning,
                probeWrapper: { candidate, property in
                    candidate.withUnsafeBufferPointer { buffer in
                        if let address = buffer.baseAddress {
                            let bufferAddress = UInt(bitPattern: address)
                            addresses.withValue { $0.append(bufferAddress) }
                        }
                    }
                    return property()
                }
            ),
            collectStats: true,
            property: { _ in true }
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
        _ = machine.startStagedJointPass(remaining: [])
        let session = try #require(machine.activeSession)
        var completed = false
        for _ in 0 ..< 1000 {
            let next = machine.next()
            let transition = try #require(next)
            if case let .stagedJointPassCompleted(accepted) = transition {
                #expect(accepted == false)
                completed = true
                break
            }
            #expect(machine.activeSession === session)
        }
        #expect(completed)
        #expect(machine.activeSession == nil)
        #expect(machine.stats.encoderProbes[.stagedJointSearch] == 128)
        #expect(addresses.value.count > 2)
        #expect(Set(addresses.value).count == 1)
    }
}
