import Exhaust
import ExhaustCore
import Foundation
import Testing

@Suite("Cooperative pipeline deadlines")
struct PipelineDeadlineTests {
    @Test("The deadline setting works through the public macro")
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

    @Test("Large deadlines saturate and the last setting wins")
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

    @Test("Reflected failures still render when the deadline prevents reduction")
    func reflectedFailureDeadline() throws {
        var report: ExhaustReport?
        let value = #exhaust(
            #gen(.int(in: 0 ... 100)),
            reflecting: 37,
            .deadline(.milliseconds(100)),
            .suppress(.all),
            .onReport { report = $0 }
        ) { _ in
            Thread.sleep(forTimeInterval: 0.15)
            return false
        }
        #expect(value == 37)
        let completed = try #require(report)
        #expect(completed.hasExceededDeadline)
        #expect(completed.reductionWasCapped)
        #expect(completed.renderedFailure != nil)
        #expect(completed.propertyInvocations == 1)
    }

    @Test("Parallel sampling drains its in-flight calls before returning")
    func parallelDeadline() throws {
        var report: ExhaustReport?
        let completedCalls = SendableBox(0)
        let value = #exhaust(
            #gen(.int(in: 0 ... 3)),
            .budget(.custom(screening: 0, sampling: 1000)),
            .deadline(.milliseconds(100)),
            .parallelize(lanes: .two),
            .suppress(.all),
            .onReport { report = $0 }
        ) { _ in
            Thread.sleep(forTimeInterval: 0.15)
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

    @Test("A run completing before its deadline keeps its full sampling budget")
    func completesBeforeDeadline() throws {
        let (value, report) = run(
            deadline: monotonicNanoseconds() + 60_000_000_000, screening: 0, collectStats: false
        ) { _ in true }
        #expect(value == nil)
        #expect(try #require(report).randomSamplingInvocations == 1000)
        #expect(try #require(report).hasExceededDeadline == false)
    }

    @Test("Expired runs invoke no property", arguments: [0, 50], [false, true])
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

    @Test("A passing in-flight call finishes before the run stops", arguments: [0, 50], [false, true])
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

    @Test("A genuine failure survives a deadline without starting reduction")
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

    @Test("Reduction uses only the time remaining in the trial")
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
        let value = __ExhaustRuntime.__exhaust(generator, settings: settings, property: property)
        return (value, report)
    }
}

private func waitUntilDeadline(_ deadline: UInt64) {
    let now = monotonicNanoseconds()
    if now < deadline {
        Thread.sleep(forTimeInterval: Double(deadline - now) / 1_000_000_000 + 0.01)
    }
}
