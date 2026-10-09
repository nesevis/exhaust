import Testing
@testable import ExhaustCore

@Suite("Reduction pass completion")
struct ReductionPassCompletionTests {
    @Test("Ordinary encoder passes report completion separately from dispatch", arguments: [EncoderName.deletion, .valueSearch], [false, true])
    func completedPassAttribution(encoder: EncoderName, acceptsProbes: Bool) throws {
        let generator = Gen.arrayOf(Gen.choose(in: 0 ... 100), within: 0 ... 5)
        let initial = [10, 20, 30]
        let tree = try #require(try Interpreters.reflect(generator, with: initial))
        var machine = ReductionMachine(
            gen: generator,
            initialTree: tree,
            initialOutput: initial,
            config: .init(maxStalls: 1, enabledEncoders: [encoder]),
            collectStats: true,
            property: { _ in acceptsProbes == false }
        )
        var completedPasses = 0
        var anyPassAccepted = false
        var timings = ReductionStats.StepTimings()
        while let transition = machine.next() {
            let previousDispatchTime = timings.dispatch
            let previousDispatchCount = timings.dispatchCount
            timings.record(transition, elapsed: 100)
            if case let .passCompleted(completedEncoder, accepted) = transition {
                #expect(completedEncoder == encoder)
                #expect(machine.activeSession == nil)
                #expect(timings.dispatch == previousDispatchTime)
                #expect(timings.dispatchCount == previousDispatchCount)
                completedPasses += 1
                anyPassAccepted = anyPassAccepted || accepted
            }
        }
        #expect(completedPasses > 0)
        #expect(completedPasses == machine.passCounter)
        #expect(anyPassAccepted == acceptsProbes)
        #expect(timings.passApplyCount == completedPasses)
        #expect(timings.passApply == UInt64(completedPasses) * 100)
        var merged = ReductionStats.StepTimings()
        merged.merge(timings)
        merged.merge(timings)
        #expect(merged.passApplyCount == completedPasses * 2)
        #expect(merged.passApply == timings.passApply * 2)
    }
}
