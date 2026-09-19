import Exhaust
import Testing

/// Requires the entire requested run to pass reflection and replay checks, without accepting skipped validation or partial generation.
func expectSuccessfulExamination(_ report: ExamineReport, samples: Int) {
    #expect(report.passed, "\(report.failures)")
    #expect(report.reflectionSkipped == false)
    #expect(report.sampleCount == samples)
    #expect(report.valuesGenerated == samples)
    #expect(report.reflectionRoundTripSuccesses == samples)
    #expect(report.replayDeterminismSuccesses == samples)
}
