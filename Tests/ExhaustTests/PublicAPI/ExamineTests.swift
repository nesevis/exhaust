import Testing
@testable import Exhaust

@Suite("#examine runtime tests")
struct ExamineTests {
    @Test("Examine passes for a simple Equatable generator")
    func simpleEquatable() {
        let report = #examine(.int(in: 0 ... 100), samples: 50)
        #expect(report.passed)
        #expect(report.valuesGenerated == 50)
    }

    @Test("Examine passes for a non-Equatable generator")
    func nonEquatable() {
        let report = #examine(.int(in: 0 ... 100).array(), samples: 50)
        #expect(report.passed)
        #expect(report.valuesGenerated > 0)
    }

    @Test("Examine is deterministic with a seed")
    func deterministicWithSeed() {
        let a = #examine(.int(in: 0 ... 1_000_000), samples: 30, seed: 42)
        let b = #examine(.int(in: 0 ... 1_000_000), samples: 30, seed: 42)
        #expect(a.valuesGenerated == b.valuesGenerated)
        #expect(a.reflectionRoundTripSuccesses == b.reflectionRoundTripSuccesses)
        #expect(a.replayDeterminismSuccesses == b.replayDeterminismSuccesses)
    }

    @Test("Examine reports reflection and replay stats")
    func reportsStats() {
        let report = #examine(.bool(), samples: 20)
        #expect(report.passed)
        #expect(report.reflectionRoundTripSuccesses == report.valuesGenerated)
        #expect(report.replayDeterminismSuccesses == report.valuesGenerated)
    }

    @Test("Examine tracks filter observations")
    func filterObservations() {
        // ~50% validity rate — should pass without warnings
        let gen = #gen(.int(in: 0 ... 100, scaling: .constant)).filter(.rejectionSampling) { $0 >= 50 }
        let report = gen.validate(samples: 50, seed: 42)
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
        var report: ValidationReport!
        withKnownIssue {
            report = gen.validate(samples: 50, seed: 99)
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
        // ~0.5% validity — well below the 2% threshold
        let gen = #gen(.int(in: 0 ... 999, scaling: .constant)).filter(.rejectionSampling) { $0 < 5 }
        withKnownIssue {
            #exhaust(gen, .budget(.custom(coverage: 0, sampling: 30))) { _ in true }
        } matching: { issue in
            issue.description.contains("Filter validity rate")
        }
    }

    @Test("#exhaust does not warn when filter validity is healthy")
    func exhaustHealthyFilterNoWarning() {
        // ~50% validity — well above the 2% threshold
        let gen = #gen(.int(in: 0 ... 100, scaling: .constant)).filter(.rejectionSampling) { $0 >= 50 }
        #exhaust(gen, .budget(.custom(coverage: 0, sampling: 30))) { _ in true }
    }
}
