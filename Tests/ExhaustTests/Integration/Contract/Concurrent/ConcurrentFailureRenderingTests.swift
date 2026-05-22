import ExhaustTestSupport
import Testing
@testable import Exhaust

@Suite("Concurrent failure rendering", .serialized, .tags(.contract))
struct ConcurrentFailureRenderingTests {
    @Test
    func `renderFailure produces full report with seed`() {
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) else { return }
        let tagged: [(ScheduleMarker, String)] = [
            (.prefix, "setup()"),
            (ScheduleMarker(rawValue: 1), "deposit(10)"),
            (ScheduleMarker(rawValue: 2), "withdraw(5)"),
        ]
        var context = FailureContext()
        context.specName = "BankSpec"
        context.seed = 42
        context.iteration = 3
        context.budget = 100
        context.originalCount = 5
        context.sequencesTested = 50

        let output = renderFailure(tagged, trace: [], context: context)
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

    @Test
    func `renderFailure without seed omits replay line`() {
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) else { return }
        let tagged: [(ScheduleMarker, String)] = [
            (ScheduleMarker(rawValue: 1), "push(1)"),
        ]
        var context = FailureContext()
        context.specName = "StackSpec"
        context.iteration = 1
        context.budget = 10
        context.originalCount = 1
        context.sequencesTested = 5

        let output = renderFailure(tagged, trace: [], context: context)
        #expect(output.contains("StackSpec failure"))
        #expect(output.contains("Reproduce:") == false)
    }

    @Test
    func `renderFailure with oracleDescription includes it`() {
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) else { return }
        let tagged: [(ScheduleMarker, String)] = [
            (ScheduleMarker(rawValue: 1), "increment()"),
        ]
        var context = FailureContext()
        context.specName = "CounterSpec"
        context.oracleDescription = "Expected 5 but got 4"
        context.iteration = 1
        context.budget = 10
        context.sequencesTested = 3

        let output = renderFailure(tagged, trace: [], context: context)
        #expect(output.contains("Expected 5 but got 4"))
    }

    @Test
    func `renderFailure delegates to renderTimeout when timedOut`() {
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) else { return }
        let tagged: [(ScheduleMarker, String)] = [
            (ScheduleMarker(rawValue: 1), "slowOp()"),
        ]
        var context = FailureContext()
        context.timedOut = true

        let output = renderFailure(tagged, trace: [], context: context)
        #expect(output.contains("timed out"))
        #expect(output.contains("drain loop stalled"))
    }

    @Test
    func `renderFailure includes scheduling caveat for preemptive random sampling`() {
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) else { return }
        let tagged: [(ScheduleMarker, String)] = [
            (ScheduleMarker(rawValue: 1), "increment()"),
            (ScheduleMarker(rawValue: 2), "decrement()"),
        ]
        var context = FailureContext()
        context.specName = "CounterSpec"
        context.seed = 99
        context.isPreemptive = true
        context.discoveryMethod = .randomSampling
        context.iteration = 1
        context.budget = 200
        context.sequencesTested = 10

        let output = renderFailure(tagged, trace: [], context: context)
        #expect(output.contains("Reproduce:"))
        #expect(output.contains("Preemptive scheduling depends on OS thread timing"))
    }

    @Test
    func `renderFailure includes scheduling caveat for preemptive coverage`() {
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) else { return }
        let tagged: [(ScheduleMarker, String)] = [
            (ScheduleMarker(rawValue: 1), "increment()"),
        ]
        var context = FailureContext()
        context.specName = "CounterSpec"
        context.isPreemptive = true
        context.discoveryMethod = .coverage
        context.iteration = 1
        context.budget = 200
        context.sequencesTested = 10

        let output = renderFailure(tagged, trace: [], context: context)
        #expect(output.contains("Preemptive scheduling depends on OS thread timing"))
    }

    @Test
    func `renderFailure omits scheduling caveat for cooperative random sampling`() {
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) else { return }
        let tagged: [(ScheduleMarker, String)] = [
            (ScheduleMarker(rawValue: 1), "increment()"),
        ]
        var context = FailureContext()
        context.specName = "CounterSpec"
        context.seed = 99
        context.discoveryMethod = .randomSampling
        context.iteration = 1
        context.budget = 200
        context.sequencesTested = 10

        let output = renderFailure(tagged, trace: [], context: context)
        #expect(output.contains("Reproduce:"))
        #expect(output.contains("Preemptive") == false)
    }

    @Test
    func `renderTimeout with partial trace includes trace lines`() {
        guard #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) else { return }
        let tagged: [(ScheduleMarker, String)] = [
            (.prefix, "init()"),
            (ScheduleMarker(rawValue: 1), "block()"),
        ]
        let trace = [
            TraceStep(index: 1, command: "init()", outcome: .ok),
            TraceStep(index: 2, command: "block()", outcome: .ok),
        ]

        let output = renderTimeout(tagged, trace: trace)
        #expect(output.contains("Partial execution trace"))
        #expect(output.contains("init()"))
    }
}
