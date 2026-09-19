import Exhaust
import Testing

@Suite("Optional examine reflection")
struct ExamineOptionalReflectionTests {
    @Test("Skipping dictionary reflection retains every generation and recorded-choice replay check")
    func dictionaryReplay() {
        let generator = ReflectiveGenerator<[Bool: Int]>.dictionary(.bool(), .int(in: -10 ... 10), count: 10)
        let report = #examine(generator, .skipReflection, .samples(100), .replay(1337), .suppress(.all)) { $0 == $1 }
        #expect(report.passed)
        #expect(report.failures.isEmpty)
        #expect(report.reflectionSkipped)
        #expect(report.valuesGenerated == 100)
        #expect(report.replayDeterminismSuccesses == 100)
        #expect(report.reflectionRoundTripSuccesses == 0)
        #expect(report.pinnedFieldCount == 0)
        #expect(report.description.contains("synthesized") == false)
    }

    @Test("Skipping reflection still records replay mismatches")
    func replayFailuresRemainVisible() {
        let report = #examine(.just(7), .skipReflection, .samples(3), .replay(1337), .suppress(.all)) { _, _ in false }
        #expect(report.passed == false)
        #expect(report.reflectionSkipped)
        #expect(report.valuesGenerated == 3)
        #expect(report.replayDeterminismSuccesses == 0)
        #expect(report.failures.count == 3)
        #expect(report.pinnedFieldCount == 0)
        for failure in report.failures {
            guard case .replayDivergence = failure else {
                Issue.record("Expected a replay failure, not a suppressed reflection diagnostic")
                continue
            }
        }
    }

    @Test("The overload without a replay comparator honours explicit reflection skipping")
    func generationOnly() {
        let generator = ReflectiveGenerator<Int>.just(7).map(String.init)
        let report = #examine(generator, .skipReflection, .samples(3), .suppress(.all))
        #expect(report.passed)
        #expect(report.failures.isEmpty)
        #expect(report.reflectionSkipped)
        #expect(report.valuesGenerated == 3)
        #expect(report.replayDeterminismSuccesses == nil)
        #expect(report.reflectionRoundTripSuccesses == 0)
    }
}
