import Exhaust
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
