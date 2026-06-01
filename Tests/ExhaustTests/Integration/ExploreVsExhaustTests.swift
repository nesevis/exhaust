import Testing
@testable import Exhaust

@Suite("Explore macro integration")
struct ExploreMacroIntegrationTests {
    @Test("#explore covers common directions")
    func coversCommonDirections() {
        let gen = #gen(.int(in: 0 ... 100))
        let report = #explore(
            gen,
            directions: [
                ("low", { $0 < 50 }),
                ("high", { $0 >= 50 }),
            ],
            .budget(.custom(coverage: 10, sampling: 200)),
            .suppress(.all)
        ) { value in
            value >= 0
        }
        #expect(report.result == nil)
        #expect(report.termination == .coverageAchieved)
        for entry in report.directionCoverage {
            #expect(entry.isCovered)
        }
    }

    @Test("#explore finds and reduces a counterexample")
    func findsCounterexample() {
        let gen = #gen(.int(in: 0 ... 100))
        let report = #explore(
            gen,
            directions: [
                ("any", { _ in true }),
            ],
            .budget(.custom(coverage: 30, sampling: 500)),
            .suppress(.all)
        ) { value in
            value < 50
        }
        #expect(report.result != nil)
        #expect(report.termination == .propertyFailed)
        if let counterexample = report.result {
            #expect(counterexample >= 50)
        }
    }

    @Test("#explore report exposes co-occurrence data")
    func coOccurrenceExposed() {
        let gen = #gen(.int(in: 0 ... 100))
        let report = #explore(
            gen,
            directions: [
                ("positive", { $0 > 0 }),
                ("above 30", { $0 > 30 }),
            ],
            .budget(.custom(coverage: 10, sampling: 200)),
            .suppress(.all)
        ) { _ in
            true
        }
        #expect(report.coOccurrence.directionCount == 2)
        #expect(report.coOccurrence.totalSampleCount > 0)
    }

    @Test("#explore with replay produces deterministic results")
    func deterministicWithReplay() {
        let gen = #gen(.int(in: 0 ... 100))
        let report1 = #explore(
            gen,
            directions: [
                ("low", { $0 < 50 }),
            ],
            .budget(.custom(coverage: 10, sampling: 200)),
            .replay(42),
            .suppress(.all)
        ) { _ in
            true
        }
        let report2 = #explore(
            gen,
            directions: [
                ("low", { $0 < 50 }),
            ],
            .budget(.custom(coverage: 10, sampling: 200)),
            .replay(42),
            .suppress(.all)
        ) { _ in
            true
        }
        #expect(report1.propertyInvocations == report2.propertyInvocations)
        #expect(report1.seed == report2.seed)
    }
}
