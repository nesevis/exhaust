import Testing
@testable import Exhaust

@Suite("Explore macro integration")
struct ExploreMacroIntegrationTests {
    @Test("#explore covers common directions")
    func coversCommonDirections() {
        let gen = #gen(.int(in: 0 ... 100))
        let report = #explore(
            gen,
            .budget(.custom(hitsPerDirection: 10, maxAttemptsPerDirection: 200)),
            .suppress(.all),
            directions: [
                ("low", { $0 < 50 }),
                ("high", { $0 >= 50 }),
            ]
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
            .budget(.custom(hitsPerDirection: 30, maxAttemptsPerDirection: 500)),
            .suppress(.all),
            directions: [
                ("any", { _ in true }),
            ]
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
            .budget(.custom(hitsPerDirection: 10, maxAttemptsPerDirection: 200)),
            .suppress(.all),
            directions: [
                ("positive", { $0 > 0 }),
                ("above 30", { $0 > 30 }),
            ]
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
            .budget(.custom(hitsPerDirection: 10, maxAttemptsPerDirection: 200)),
            .replay(42),
            .suppress(.all),
            directions: [
                ("low", { $0 < 50 }),
            ]
        ) { _ in
            true
        }
        let report2 = #explore(
            gen,
            .budget(.custom(hitsPerDirection: 10, maxAttemptsPerDirection: 200)),
            .replay(42),
            .suppress(.all),
            directions: [
                ("low", { $0 < 50 }),
            ]
        ) { _ in
            true
        }
        #expect(report1.propertyInvocations == report2.propertyInvocations)
        #expect(report1.seed == report2.seed)
    }
}
