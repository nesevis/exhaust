import ExhaustTestSupport
import Testing
@testable import Exhaust

@Suite("Concurrent failure rendering", .serialized, .tags(.stateMachine))
struct ConcurrentFailureRenderingTests {
    @Test("renderFailure produces full report with seed")
    func renderFailureProducesFullReportWithSeed() {
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) else {
            return
        }
        let tagged: [(ScheduleMarker, String)] = [
            (.prefix, "setup()"),
            (ScheduleMarker(rawValue: 1), "deposit(10)"),
            (ScheduleMarker(rawValue: 2), "withdraw(5)"),
        ]
        var context = __ExhaustRuntime.FailureContext()
        context.specName = "BankSpec"
        context.seed = 42
        context.iteration = 3
        context.budget = 100
        context.originalCount = 5
        context.sequencesTested = 50
        context.replaySeed = ReplaySeed.Resolved.sampling(seed: 42, iteration: 3).encoded

        let output = __ExhaustRuntime.renderFailure(tagged, trace: [], context: context)
        #expect(output.contains("BankSpec failure"))
        #expect(output.contains("seed"))
        #expect(output.contains("Reduced from 5 to 3 commands"))
        #expect(output.contains("Sequential prefix:"))
        #expect(output.contains("setup()"))
        #expect(output.contains("Lane A:"))
        #expect(output.contains("Lane B:"))
        #expect(output.contains("Command sequences tested: 50"))
        #expect(output.contains("Reproduce:"))
    }

    @Test("renderFailure without seed omits replay line")
    func renderFailureWithoutSeedOmitsReplayLine() {
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) else {
            return
        }
        let tagged: [(ScheduleMarker, String)] = [
            (ScheduleMarker(rawValue: 1), "push(1)"),
        ]
        var context = __ExhaustRuntime.FailureContext()
        context.specName = "StackSpec"
        context.iteration = 1
        context.budget = 10
        context.originalCount = 1
        context.sequencesTested = 5

        let output = __ExhaustRuntime.renderFailure(tagged, trace: [], context: context)
        #expect(output.contains("StackSpec failure"))
        #expect(output.contains("Reproduce:") == false)
    }

    @Test("renderFailure with oracleDescription includes it")
    func renderFailureWithOracleDescriptionIncludesIt() {
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) else {
            return
        }
        let tagged: [(ScheduleMarker, String)] = [
            (ScheduleMarker(rawValue: 1), "increment()"),
        ]
        var context = __ExhaustRuntime.FailureContext()
        context.specName = "CounterSpec"
        context.oracleDescription = "Expected 5 but got 4"
        context.iteration = 1
        context.budget = 10
        context.sequencesTested = 3

        let output = __ExhaustRuntime.renderFailure(tagged, trace: [], context: context)
        #expect(output.contains("Expected 5 but got 4"))
    }

    @Test("renderFailure includes scheduling caveat for preemptive random sampling")
    func renderFailureIncludesSchedulingCaveatForPreemptiveRandomSampling() {
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) else {
            return
        }
        let tagged: [(ScheduleMarker, String)] = [
            (ScheduleMarker(rawValue: 1), "increment()"),
            (ScheduleMarker(rawValue: 2), "decrement()"),
        ]
        var context = __ExhaustRuntime.FailureContext()
        context.specName = "CounterSpec"
        context.seed = 99
        context.isPreemptive = true
        context.discoveryMethod = .randomSampling
        context.iteration = 1
        context.budget = 200
        context.sequencesTested = 10
        context.replaySeed = ReplaySeed.Resolved.sampling(seed: 99, iteration: 1).encoded

        let output = __ExhaustRuntime.renderFailure(tagged, trace: [], context: context)
        #expect(output.contains("Reproduce:"))
        #expect(output.contains("Preemptive scheduling depends on OS thread timing"))
    }

    @Test("renderFailure includes scheduling caveat for preemptive coverage")
    func renderFailureIncludesSchedulingCaveatForPreemptiveCoverage() {
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) else {
            return
        }
        let tagged: [(ScheduleMarker, String)] = [
            (ScheduleMarker(rawValue: 1), "increment()"),
        ]
        var context = __ExhaustRuntime.FailureContext()
        context.specName = "CounterSpec"
        context.isPreemptive = true
        context.discoveryMethod = .coverage
        context.iteration = 1
        context.budget = 200
        context.sequencesTested = 10

        let output = __ExhaustRuntime.renderFailure(tagged, trace: [], context: context)
        #expect(output.contains("Preemptive scheduling depends on OS thread timing"))
    }

    @Test("renderFailure omits scheduling caveat for cooperative random sampling")
    func renderFailureOmitsSchedulingCaveatForCooperativeRandomSampling() {
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) else {
            return
        }
        let tagged: [(ScheduleMarker, String)] = [
            (ScheduleMarker(rawValue: 1), "increment()"),
        ]
        var context = __ExhaustRuntime.FailureContext()
        context.specName = "CounterSpec"
        context.seed = 99
        context.discoveryMethod = .randomSampling
        context.iteration = 1
        context.budget = 200
        context.sequencesTested = 10
        context.replaySeed = ReplaySeed.Resolved.sampling(seed: 99, iteration: 1).encoded

        let output = __ExhaustRuntime.renderFailure(tagged, trace: [], context: context)
        #expect(output.contains("Reproduce:"))
        #expect(output.contains("Preemptive") == false)
    }
}
