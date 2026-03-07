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
}
