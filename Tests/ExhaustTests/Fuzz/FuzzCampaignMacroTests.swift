import ExhaustTestSupport
import IssueReporting
import Testing
@testable import Exhaust

/// Macro calls select production coverage, so they must not overlap tests that register synthetic coverage regions.
extension CoverageRegistryTests {
    @Suite("Campaign macro reporting")
    struct FuzzCampaignMacroTests {
        @Test("Runtime command-report fixture: two explore calls in one Swift Testing case", arguments: [UInt64(11), 22])
        func multipleExploreCalls(seed: UInt64) async {
            let reporter = RecordingIssueReporter()
            let (first, second) = await withIssueReporters([reporter]) {
                // Both skipped invocations must remain visible in command JSON despite attachment suppression.
                let first = await #explore(.int(), time: .seconds(1), .replay(.numeric(seed)), .suppress(.all)) { _ in true }
                let second = await #explore(.int(), time: .seconds(1), .replay(.numeric(seed)), .suppress(.all)) { _ in true }
                return (first, second)
            }
            #expect(first.seed == seed)
            #expect(second.seed == seed)
            #expect(first.termination == .instrumentationMissing)
            #expect(second.termination == .instrumentationMissing)
            #expect(first.attempts.total == 0)
            #expect(second.attempts.total == 0)
            #expect(reporter.issues.map(\.message) == Array(repeating: __ExhaustRuntime.missingInstrumentationMessage, count: 2))
            #expect(reporter.issues.allSatisfy { $0.severity == .warning })
        }
    }
}
