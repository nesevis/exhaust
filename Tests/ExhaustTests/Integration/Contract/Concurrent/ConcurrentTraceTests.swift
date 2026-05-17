@testable import Exhaust
import Testing

@Suite("Concurrent trace parsing")
struct ConcurrentTraceTests {
    @Test("Collapses no-op suspend/resume pairs with no interleaving between them")
    func collapsesNoOpSuspensions() {
        let raw = [
            "STARTED:a:1A foo",
            "SUSPENDED:a",
            "RESUMED:a",
            "COMPLETED:a:1A foo",
        ]
        let steps = parseTrace(raw)
        #expect(steps.count == 1)
        #expect(steps[0].command.hasSuffix("(completed)"))
    }

    @Test("Preserves meaningful suspensions when another lane ran between suspend and resume")
    func preservesMeaningfulSuspensions() {
        let raw = [
            "STARTED:a:1A foo",
            "SUSPENDED:a",
            "STARTED:b:1B bar",
            "COMPLETED:b:1B bar",
            "RESUMED:a",
            "COMPLETED:a:1A foo",
        ]
        let steps = parseTrace(raw)
        let hasSuspended = steps.contains { $0.command.hasSuffix("(suspended)") }
        let hasResumed = steps.contains { $0.command.hasSuffix("(resumed)") }
        #expect(hasSuspended)
        #expect(hasResumed)
    }

    @Test("Collapses adjacent started+completed into single entry")
    func collapsesStartedCompleted() {
        let raw = [
            "STARTED:a:1A deposit",
            "COMPLETED:a:1A deposit",
            "STARTED:b:1B withdraw",
            "COMPLETED:b:1B withdraw",
        ]
        let steps = parseTrace(raw)
        #expect(steps.count == 2)
        #expect(steps[0].command == "1A deposit (completed)")
        #expect(steps[1].command == "1B withdraw (completed)")
    }

    @Test("Handles prefix commands correctly")
    func prefixCommands() {
        let raw = [
            "STARTED:prefix:setup",
            "COMPLETED:prefix:setup",
            "STARTED:a:1A action",
            "COMPLETED:a:1A action",
        ]
        let steps = parseTrace(raw)
        #expect(steps.count == 2)
        #expect(steps[0].command == "setup (prefix)")
        #expect(steps[1].command == "1A action (completed)")
    }

    @Test("Failure step carries the invariant name")
    func failureCarriesInvariantName() {
        let raw = [
            "STARTED:a:1A increment",
            "FAILED:a:1A increment:matchesModel",
        ]
        let steps = parseTrace(raw)
        let failedStep = steps.first { step in
            if case .invariantFailed = step.outcome { return true }
            return false
        }
        #expect(failedStep != nil)
        if case let .invariantFailed(name) = failedStep?.outcome {
            #expect(name == "matchesModel")
        }
    }
}
