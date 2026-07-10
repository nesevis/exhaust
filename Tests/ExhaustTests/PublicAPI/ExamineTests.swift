import Testing
@testable import Exhaust

@Suite("#examine runtime tests")
struct ExamineTests {
    @Test("Examine passes for a simple Equatable generator")
    func simpleEquatable() {
        let report = #examine(.int(in: 0 ... 100), .budget(50))
        #expect(report.passed)
        #expect(report.valuesGenerated == 50)
    }

    @Test("Examine passes for a non-Equatable generator")
    func nonEquatable() {
        let report = #examine(.int(in: 0 ... 100).array(), .budget(50))
        #expect(report.passed)
        #expect(report.valuesGenerated > 0)
    }

    @Test("Examine is deterministic with a seed")
    func deterministicWithSeed() {
        let a = #examine(.int(in: 0 ... 1_000_000), .budget(30), .replay(42))
        let b = #examine(.int(in: 0 ... 1_000_000), .budget(30), .replay(42))
        #expect(a.valuesGenerated == b.valuesGenerated)
        #expect(a.reflectionRoundTripSuccesses == b.reflectionRoundTripSuccesses)
    }

    @Test("Examine reports reflection and replay stats")
    func reportsStats() {
        let report = #examine(.bool(), .budget(20))
        #expect(report.passed)
        #expect(report.reflectionRoundTripSuccesses == report.valuesGenerated)
    }

    @Test("Examine tracks filter observations")
    func filterObservations() {
        // ~50% validity rate — should pass without warnings
        let gen = #gen(.int(in: 0 ... 100, scaling: .constant)).filter(.rejectionSampling) { $0 >= 50 }
        let report = gen.gen.validate(samples: 50, seed: 42)
        #expect(report.passed)
        #expect(report.filterObservations.count == 1)
        let observation = report.filterObservations.values.first!
        #expect(observation.attempts > 0)
        #expect(observation.passes == report.valuesGenerated)
        #expect(observation.validityRate > 0.3)
    }

    @Test("Examine reports low filter validity rate")
    func lowFilterValidityRate() throws {
        // ~1% validity rate (10 out of 1001) — should trigger warning
        let gen = #gen(.int(in: 0 ... 1000, scaling: .constant)).filter(.rejectionSampling) { $0 < 10 }
        var report: ExamineReport!
        withKnownIssue {
            report = gen.gen.validate(samples: 50, seed: 99)
        }
        let lowValidityFailures = report.failures.compactMap { failure -> Double? in
            if case let .lowFilterValidityRate(_, rate, _) = failure { return rate }
            return nil
        }
        #expect(lowValidityFailures.count == 1)
        let first = try #require(lowValidityFailures.first)
        #expect(first < 0.05)
    }

    @Test("#exhaust emits runtime warning for sparse filter")
    func exhaustSparseFilterWarning() {
        withKnownIssue {
            // ~0.5% validity — well below the 2% threshold
            let gen = #gen(.int(in: 0 ... 999, scaling: .constant))
                .filter(.rejectionSampling) { $0 < 5 }
            #exhaust(gen, .budget(.custom(screening: 0, sampling: 30))) { _ in true }
        } matching: { issue in
            issue.description.contains("Filter validity rate")
                || issue.description.contains("retry budget")
                || issue.description.contains("never invoked")
        }
    }

    @Test("#exhaust does not warn when filter validity is healthy")
    func exhaustHealthyFilterNoWarning() {
        // ~50% validity — well above the 2% threshold
        let gen = #gen(.int(in: 0 ... 100, scaling: .constant)).filter(.rejectionSampling) { $0 >= 50 }
        #exhaust(gen, .budget(.custom(screening: 0, sampling: 30))) { _ in true }
    }

    // MARK: - Severity tests

    @Test("Silent severity produces no test failures")
    func silentSeverityNoFailures() {
        let gen = #gen(.int(in: 1 ... 100)).mapped(
            forward: { $0 * 2 },
            backward: { $0 } // wrong inverse
        )
        let report = gen.gen.validate(
            samples: 10,
            seed: 42,
            reporting: ExamineReportingConfiguration(from: [.severity(.silent)])
        )
        #expect(report.passed == false)
    }

    @Test("Per-check severity overrides global severity")
    func perCheckOverridesGlobal() {
        let config = ExamineReportingConfiguration(from: [
            .severity(.silent),
            .reflection(.warning),
        ])
        #expect(config.reflectionSeverity == .warning)
        #expect(config.filterHealthSeverity == .silent)
    }

    @Test("Default configuration uses error severity for all checks")
    func defaultSeverityIsError() {
        let config = ExamineReportingConfiguration(from: [])
        #expect(config.reflectionSeverity == .error)
        #expect(config.filterHealthSeverity == .error)
        #expect(config.samples == 200)
        #expect(config.replaySeed == nil)
    }

    @Test("Samples and replay seed are resolved from settings")
    func samplesAndSeedResolution() {
        let config = ExamineReportingConfiguration(from: [
            .budget(500),
            .replay(42),
        ])
        #expect(config.samples == 500)
        #expect(config.replaySeed != nil)
    }
}
