import Exhaust
import ExhaustCore
import Foundation
import Testing

@Suite("Cooperative pipeline deadlines")
struct PipelineDeadlineTests {
    @Test("The deadline setting works through the public macro", .timeLimit(.minutes(1)))
    func macroDeadline() throws {
        var report: ExhaustReport?
        let value = #exhaust(
            #gen(.int(in: 0 ... 3)), .deadline(.zero), .suppress(.all), .onReport { report = $0 }
        ) { _ in
            Issue.record("A zero deadline must not invoke the property")
            return false
        }
        #expect(value == nil)
        #expect(try #require(report).hasExceededDeadline)
    }

    @Test("Large deadlines saturate and the last setting wins", .timeLimit(.minutes(1)))
    func saturatedDeadline() throws {
        var report: ExhaustReport?
        let value = #exhaust(
            #gen(.int(in: 0 ... 3)),
            .budget(.custom(screening: 0, sampling: 3)),
            .deadline(.zero),
            .deadline(.nanoseconds(.max)),
            .suppress(.all),
            .onReport { report = $0 }
        ) { _ in true }
        #expect(value == nil)
        let completed = try #require(report)
        #expect(completed.randomSamplingInvocations == 3)
        #expect(completed.hasExceededDeadline == false)
    }

    @Test("Reflected failures still render when the deadline prevents reduction", .timeLimit(.minutes(1)))
    func reflectedFailureDeadline() throws {
        let deadline = monotonicNanoseconds() + 1_000_000_000
        let (value, report) = run(
            deadline: deadline,
            screening: 0,
            collectStats: false,
            generator: #gen(.int(in: 0 ... 100)),
            reflecting: 37
        ) { _ in
            waitUntilDeadline(deadline)
            return false
        }
        #expect(value == 37)
        let completed = try #require(report)
        #expect(completed.hasExceededDeadline)
        #expect(completed.reductionWasCapped)
        #expect(completed.renderedFailure != nil)
        #expect(completed.propertyInvocations == 1)
    }

    @Test("Parallel sampling drains its in-flight calls before returning", .timeLimit(.minutes(1)))
    func parallelDeadline() throws {
        let deadline = monotonicNanoseconds() + 1_000_000_000
        let completedCalls = SendableBox(0)
        let (value, report) = run(
            deadline: deadline, screening: 0, collectStats: false, lanes: .two
        ) { _ in
            waitUntilDeadline(deadline)
            completedCalls.withValue { $0 += 1 }
            return true
        }
        #expect(value == nil)
        let completed = try #require(report)
        #expect(completed.hasExceededDeadline)
        #expect(completedCalls.value > 0)
        #expect(completedCalls.value <= 2)
        #expect(completed.propertyInvocations == completedCalls.value)
    }

    @Test("A run completing before its deadline keeps its full sampling budget", .timeLimit(.minutes(1)))
    func completesBeforeDeadline() throws {
        let (value, report) = run(
            deadline: monotonicNanoseconds() + 60_000_000_000, screening: 0, collectStats: false
        ) { _ in true }
        #expect(value == nil)
        #expect(try #require(report).randomSamplingInvocations == 1000)
        #expect(try #require(report).hasExceededDeadline == false)
    }

    @Test("Expired runs invoke no property", .timeLimit(.minutes(1)), arguments: [0, 50], [false, true])
    func expiredRun(screening: Int, collectStats: Bool) throws {
        let (value, report) = run(deadline: 0, screening: screening, collectStats: collectStats) { _ in
            Issue.record("An expired run must not invoke the property")
            return false
        }
        #expect(value == nil)
        let completed = try #require(report)
        #expect(completed.propertyInvocations == 0)
        #expect(completed.hasExceededDeadline)
        #expect(completed.reductionInvocations == 0)
    }

    @Test("A passing in-flight call finishes before the run stops", .timeLimit(.minutes(1)), arguments: [0, 50], [false, true])
    func deadlineDuringProperty(screening: Int, collectStats: Bool) throws {
        let deadline = monotonicNanoseconds() + 1_000_000_000
        let calls = SendableBox(0)
        let (value, report) = run(deadline: deadline, screening: screening, collectStats: collectStats) { _ in
            calls.withValue { $0 += 1 }
            waitUntilDeadline(deadline)
            return true
        }
        #expect(value == nil)
        #expect(calls.value == 1)
        let completed = try #require(report)
        #expect(completed.propertyInvocations == 1)
        #expect(completed.hasExceededDeadline)
        #expect(completed.reductionInvocations == 0)
        #expect(completed.replaySeed == nil)
        #expect(completed.randomSamplingInvocations == (screening == 0 ? 1 : 0))
    }

    @Test("A genuine failure survives a deadline without starting reduction", .timeLimit(.minutes(1)))
    func deadlineDuringFailure() throws {
        let deadline = monotonicNanoseconds() + 1_000_000_000
        let (value, report) = run(deadline: deadline, screening: 0, collectStats: false) { _ in
            waitUntilDeadline(deadline)
            return false
        }
        #expect(value != nil)
        let completed = try #require(report)
        #expect(completed.randomSamplingInvocations == 1)
        #expect(completed.reductionInvocations == 0)
        #expect(completed.reductionWasCapped)
        #expect(completed.hasExceededDeadline)
        #expect(completed.renderedFailure != nil)
        #expect(completed.replaySeed != nil)
    }

    @Test("Reduction uses only the time remaining in the trial", .timeLimit(.minutes(1)))
    func deadlineDuringReduction() throws {
        let deadline = monotonicNanoseconds() + 1_000_000_000
        let calls = SendableBox(0)
        let generator = ReflectiveGenerator<Int>.getSize { .just(Int($0)) }.resize(100)
        let (value, report) = run(
            deadline: deadline, screening: 0, collectStats: false, generator: generator
        ) { _ in
            let call = calls.withValue { count in
                count += 1
                return count
            }
            if call > 1 {
                waitUntilDeadline(deadline)
            }
            return false
        }
        #expect(value != nil)
        let completed = try #require(report)
        #expect(completed.randomSamplingInvocations == 1)
        #expect(completed.reductionInvocations > 0)
        #expect(completed.reductionWasCapped)
    }

    /// Exercises public settings through the macro runtime, keeping reports available for assertions.
    private func run(
        deadline: UInt64,
        screening: Int,
        collectStats: Bool,
        generator: ReflectiveGenerator<Int>? = nil,
        reflecting: Int? = nil,
        lanes: ConcurrencyLevel? = nil,
        property: @escaping @Sendable (Int) -> Bool
    ) -> (Int?, ExhaustReport?) {
        var report: ExhaustReport?
        let generator = generator ?? #gen(.int(in: 0 ... 3, scaling: .constant))
        var settings: [PropertySettings] = [
            .suppress(.all),
            .budget(.custom(screening: screening, sampling: 1000)),
            .replay(.numeric(42)),
            .onReport { report = $0 },
        ]
        let now = monotonicNanoseconds()
        settings.append(.deadline(.nanoseconds(deadline > now ? deadline - now : 0)))
        if collectStats {
            settings.append(.collectOpenPBTStats)
        }
        if let lanes {
            settings.append(.parallelize(lanes: lanes))
        }
        let value = __ExhaustRuntime.__exhaust(
            generator, settings: settings, reflecting: reflecting, property: property
        )
        return (value, report)
    }
}

/// Blocks until the stamped deadline has passed, with a margin.
///
/// The run stamps its own deadline later than the test does, when it parses its settings, so returning at the stamped instant can return before the run's real deadline. The margin is 100 ms because under load that gap has been seen to exceed 10 ms.
///
/// This is the file's only sleep. A deadline is compared inline against `monotonicNanoseconds()` and nothing signals a test when it passes, so real time has to elapse. A new deadline test calls this helper rather than adding another `Thread.sleep`.
private func waitUntilDeadline(_ deadline: UInt64) {
    let now = monotonicNanoseconds()
    if now < deadline {
        Thread.sleep(forTimeInterval: Double(deadline - now) / 1_000_000_000 + 0.1)
    }
}
