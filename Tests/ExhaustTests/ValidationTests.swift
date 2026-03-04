import Testing
@testable import Exhaust
@_spi(ExhaustInternal) import ExhaustCore

@Suite("Generator Validation")
struct ValidationTests {
    @Test("Correct generator passes validation")
    func correctGeneratorPasses() {
        let gen = #gen(.int(in: 1 ... 100))
        let report = gen.validate(samples: 50, seed: 42)

        #expect(report.passed)
        #expect(report.valuesGenerated == 50)
        #expect(report.reflectionRoundTripSuccesses == 50)
        #expect(report.replayDeterminismSuccesses == 50)
    }

    @Test("Bad backward mapping fails round-trip")
    func badBackwardMappingFails() {
        let gen = #gen(.int(in: 1 ... 100)).mapped(
            forward: { $0 * 2 },
            backward: { $0 } // wrong inverse — should be { $0 / 2 }
        )

        withKnownIssue {
            let report = gen.validate(samples: 50, seed: 42)
            #expect(!report.passed)
            #expect(report.failures.contains { failure in
                if case .reflectionRoundTripMismatch = failure { return true }
                return false
            })
        }
    }

    @Test("Constant generator passes validation")
    func constantGeneratorPasses() {
        let gen = ReflectiveGenerator<Int>.just(42)
        let report = gen.validate(samples: 50, seed: 42)

        #expect(report.passed)
        #expect(report.uniquenessRate <= 1.0 / Double(report.valuesGenerated) + 0.01)
    }

    @Test("Non-Equatable type validates via choice-sequence comparison")
    func nonEquatablePathWorks() {
        struct Wrapper {
            let value: Int
        }

        let gen: ReflectiveGenerator<Wrapper> = #gen(.int(in: 0 ... 50)).mapped(
            forward: { Wrapper(value: $0) },
            backward: { $0.value }
        )

        let report = gen.validate(samples: 50, seed: 42)
        #expect(report.passed)
        #expect(report.valuesGenerated == 50)
    }

    @Test("Report stats are populated correctly")
    func reportStatsPopulated() {
        let gen = #gen(.int(in: 0 ... 1000))
        let report = gen.validate(samples: 100, seed: 7)

        #expect(report.sampleCount == 100)
        #expect(report.valuesGenerated > 0)
        #expect(report.reflectionSuccessRate == 1.0)
        #expect(report.uniquenessRate > 0)
        #expect(report.uniqueChoiceSequences > 1)
        #expect(report.failures.isEmpty)
    }
}
