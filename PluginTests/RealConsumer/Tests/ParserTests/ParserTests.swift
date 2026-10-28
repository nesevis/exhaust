import Exhaust
import Foundation
import Parser
import Testing

@Test func dormantProperty() async {
    let report = await #explore(#gen(.int(in: -1000...1000)), time: .seconds(60)) { _ async in
        #expect(Bool(false), "An uninstrumented property must not run")
    }
    #expect(report.termination == .instrumentationMissing)
    #expect(report.attempts.total == 0)
    #expect(report.timing.elapsed == .zero)
}

@Test func instrumentedProperty() async {
    // The smoke command overrides this to one second. Without the override the elapsed-time
    // assertion fails, so this validates the actual runtime path as well as environment delivery.
    let report = await #explore(#gen(.int(in: -1000...1000)), time: .seconds(20)) { value async in
        Parser.accepts(value) == (value >= 10)
    }
    #expect(report.coverage.coveredEdges > 1)
    #expect(report.clusters.isEmpty)
    #expect(report.timing.elapsed < .seconds(10))
}

// Two cases at one call site, each running two campaigns, so the command must keep all four apart rather than merging them by test or source location.
@Test(arguments: [UInt64(1), 2]) func parameterizedProperty(seed: UInt64) async {
    for _ in 0 ..< 2 {
        let report = await #explore(#gen(.int(in: -1000...1000)), time: .seconds(20), .replay(.numeric(seed))) { value async in
            Parser.accepts(value) == (value >= 10)
        }
        #expect(report.outcome == .passed)
    }
}

@Test func failingProperty() async {
    await #explore(#gen(.int(in: -1000...1000)), time: .seconds(20), .failFast) { value async in
        Parser.accepts(value)
    }
}

// Traps only when the e2e script sets EXHAUST_E2E_TRAP, so the command records an interrupted campaign; the script's next run without it resumes the checkpoint and reports the predecessor's trap.
@Test func trappingProperty() async {
    let trapEnabled = ProcessInfo.processInfo.environment["EXHAUST_E2E_TRAP"] == "1"
    await #explore(#gen(.int(in: -1000...1000)), time: .seconds(20)) { value async in
        if trapEnabled, Parser.accepts(value), value > 500 {
            fatalError("EXHAUST_E2E_TRAP")
        }
        return true
    }
}

@Test func stateMachineProperty() async {
    let report = await #explore(TallySpec.self, mode: .sequential, time: .seconds(20))
    #expect(report.outcome == .passed)
}

// MARK: - Specs

@StateMachine
final class TallySpec {
    var expected = 0
    @SystemUnderTest var tally = Tally()

    @Invariant
    func totalsMatch() -> Bool {
        tally.total == expected
    }

    @Command(weight: 3, .int(in: -100...100))
    func add(value: Int) throws {
        expected += value
        tally.add(value)
    }

    @Command(weight: 1)
    func reset() throws {
        expected = 0
        tally.reset()
    }

    func failureDescription() -> String? {
        "expected: \(expected), tally: \(tally.total)"
    }
}
