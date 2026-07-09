import ExhaustTestSupport
import Testing
@testable import Exhaust

@Suite("Concurrent trace parsing", .serialized, .tags(.stateMachine))
struct ConcurrentTraceTests {
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Collapses no-op suspend/resume pairs with no interleaving between them")
    func collapsesNoOpSuspendresumePairsWithNoInterleavingBetweenThem() {
        let events: [TraceEvent] = [
            TraceEvent(kind: .started, lane: .a, label: "1A foo"),
            TraceEvent(kind: .suspended, lane: .a, label: ""),
            TraceEvent(kind: .resumed, lane: .a, label: ""),
            TraceEvent(kind: .completed, lane: .a, label: "1A foo"),
        ]
        let steps = __ExhaustRuntime.buildTrace(events)
        #expect(steps.count == 1)
        #expect(steps[0].command.hasSuffix("(completed)"))
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Preserves meaningful suspensions when another lane ran between suspend and resume")
    func preservesMeaningfulSuspensionsWhenAnotherLaneRanBetweenSuspendAndResume() {
        let events: [TraceEvent] = [
            TraceEvent(kind: .started, lane: .a, label: "1A foo"),
            TraceEvent(kind: .suspended, lane: .a, label: ""),
            TraceEvent(kind: .started, lane: .b, label: "1B bar"),
            TraceEvent(kind: .completed, lane: .b, label: "1B bar"),
            TraceEvent(kind: .resumed, lane: .a, label: ""),
            TraceEvent(kind: .completed, lane: .a, label: "1A foo"),
        ]
        let steps = __ExhaustRuntime.buildTrace(events)
        let hasSuspended = steps.contains { $0.command.hasSuffix("(suspended)") }
        let hasResumed = steps.contains { $0.command.hasSuffix("(resumed)") }
        #expect(hasSuspended)
        #expect(hasResumed)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Collapses adjacent started+completed into single entry")
    func collapsesAdjacentStartedcompletedIntoSingleEntry() {
        let events: [TraceEvent] = [
            TraceEvent(kind: .started, lane: .a, label: "1A deposit"),
            TraceEvent(kind: .completed, lane: .a, label: "1A deposit"),
            TraceEvent(kind: .started, lane: .b, label: "1B withdraw"),
            TraceEvent(kind: .completed, lane: .b, label: "1B withdraw"),
        ]
        let steps = __ExhaustRuntime.buildTrace(events)
        #expect(steps.count == 2)
        #expect(steps[0].command == "1A deposit (completed)")
        #expect(steps[1].command == "1B withdraw (completed)")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Handles prefix commands correctly")
    func handlesPrefixCommandsCorrectly() {
        let events: [TraceEvent] = [
            TraceEvent(kind: .started, lane: .prefix, label: "setup"),
            TraceEvent(kind: .completed, lane: .prefix, label: "setup"),
            TraceEvent(kind: .started, lane: .a, label: "1A action"),
            TraceEvent(kind: .completed, lane: .a, label: "1A action"),
        ]
        let steps = __ExhaustRuntime.buildTrace(events)
        #expect(steps.count == 2)
        #expect(steps[0].command == "setup (prefix)")
        #expect(steps[1].command == "1A action (completed)")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Failure step carries the invariant name")
    func failureStepCarriesTheInvariantName() {
        let events: [TraceEvent] = [
            TraceEvent(kind: .started, lane: .a, label: "1A increment"),
            TraceEvent(kind: .failed(message: "matchesModel", source: .invariant), lane: .a, label: "1A increment"),
        ]
        let steps = __ExhaustRuntime.buildTrace(events)
        let failedStep = steps.first { step in
            if case .invariantFailed = step.outcome { return true }
            return false
        }
        #expect(failedStep != nil)
        if case let .invariantFailed(name) = failedStep?.outcome {
            #expect(name == "matchesModel")
        }
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Failing prefix command appears once, not twice")
    func failingPrefixCommandAppearsOnce() {
        let events: [TraceEvent] = [
            TraceEvent(kind: .started, lane: .prefix, label: "enqueue(5)"),
            TraceEvent(kind: .failed(message: "matchesModel", source: .invariant), lane: .prefix, label: "enqueue(5)"),
        ]
        let steps = __ExhaustRuntime.buildTrace(events)
        #expect(steps.count == 1)
        if case let .invariantFailed(name) = steps.first?.outcome {
            #expect(name == "matchesModel")
        } else {
            Issue.record("Expected invariantFailed outcome")
        }
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Check failure renders as checkFailed, not invariantFailed")
    func checkFailureRendersAsCheckFailed() {
        let events: [TraceEvent] = [
            TraceEvent(kind: .started, lane: .a, label: "1A withdraw"),
            TraceEvent(kind: .failed(message: "balance must match", source: .check), lane: .a, label: "1A withdraw"),
        ]
        let steps = __ExhaustRuntime.buildTrace(events)
        let failedStep = steps.first { step in
            if case .checkFailed = step.outcome { return true }
            return false
        }
        #expect(failedStep != nil, "check() failure should render as checkFailed, not invariantFailed")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Skipped command renders as skipped, not ok")
    func skippedCommandRendersAsSkipped() {
        let events: [TraceEvent] = [
            TraceEvent(kind: .started, lane: .a, label: "1A withdraw"),
            TraceEvent(kind: .skipped, lane: .a, label: "1A withdraw"),
        ]
        let steps = __ExhaustRuntime.buildTrace(events)
        #expect(steps.count == 1)
        #expect(steps.first?.outcome == .skipped)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Skipped prefix command renders as skipped, not ok")
    func skippedPrefixCommandRendersAsSkipped() {
        let events: [TraceEvent] = [
            TraceEvent(kind: .started, lane: .prefix, label: "withdraw"),
            TraceEvent(kind: .skipped, lane: .prefix, label: "withdraw"),
        ]
        let steps = __ExhaustRuntime.buildTrace(events)
        #expect(steps.count == 1)
        #expect(steps.first?.outcome == .skipped)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Command name containing colons does not break parsing")
    func commandNameContainingColonsDoesNotBreakParsing() {
        let events: [TraceEvent] = [
            TraceEvent(kind: .started, lane: .a, label: "1A reset(mode:forced)"),
            TraceEvent(kind: .completed, lane: .a, label: "1A reset(mode:forced)"),
        ]
        let steps = __ExhaustRuntime.buildTrace(events)
        #expect(steps.count == 1)
        #expect(steps[0].command == "1A reset(mode:forced) (completed)")
    }
}

// MARK: - Helpers

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private extension TraceEvent.Lane {
    static let a = TraceEvent.Lane.lane(LaneID(index: 0))
    static let b = TraceEvent.Lane.lane(LaneID(index: 1))
}
