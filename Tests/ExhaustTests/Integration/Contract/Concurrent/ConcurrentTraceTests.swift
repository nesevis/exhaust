import ExhaustTestSupport
import Testing
@testable import Exhaust

@Suite("Concurrent trace parsing", .serialized, .tags(.contract))
struct ConcurrentTraceTests {
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test
    func `Collapses no-op suspend/resume pairs with no interleaving between them`() {
        let events: [TraceEvent] = [
            TraceEvent(kind: .started, lane: "a", label: "1A foo"),
            TraceEvent(kind: .suspended, lane: "a", label: ""),
            TraceEvent(kind: .resumed, lane: "a", label: ""),
            TraceEvent(kind: .completed, lane: "a", label: "1A foo"),
        ]
        let steps = buildTrace(events)
        #expect(steps.count == 1)
        #expect(steps[0].command.hasSuffix("(completed)"))
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test
    func `Preserves meaningful suspensions when another lane ran between suspend and resume`() {
        let events: [TraceEvent] = [
            TraceEvent(kind: .started, lane: "a", label: "1A foo"),
            TraceEvent(kind: .suspended, lane: "a", label: ""),
            TraceEvent(kind: .started, lane: "b", label: "1B bar"),
            TraceEvent(kind: .completed, lane: "b", label: "1B bar"),
            TraceEvent(kind: .resumed, lane: "a", label: ""),
            TraceEvent(kind: .completed, lane: "a", label: "1A foo"),
        ]
        let steps = buildTrace(events)
        let hasSuspended = steps.contains { $0.command.hasSuffix("(suspended)") }
        let hasResumed = steps.contains { $0.command.hasSuffix("(resumed)") }
        #expect(hasSuspended)
        #expect(hasResumed)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test
    func `Collapses adjacent started+completed into single entry`() {
        let events: [TraceEvent] = [
            TraceEvent(kind: .started, lane: "a", label: "1A deposit"),
            TraceEvent(kind: .completed, lane: "a", label: "1A deposit"),
            TraceEvent(kind: .started, lane: "b", label: "1B withdraw"),
            TraceEvent(kind: .completed, lane: "b", label: "1B withdraw"),
        ]
        let steps = buildTrace(events)
        #expect(steps.count == 2)
        #expect(steps[0].command == "1A deposit (completed)")
        #expect(steps[1].command == "1B withdraw (completed)")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test
    func `Handles prefix commands correctly`() {
        let events: [TraceEvent] = [
            TraceEvent(kind: .started, lane: "prefix", label: "setup"),
            TraceEvent(kind: .completed, lane: "prefix", label: "setup"),
            TraceEvent(kind: .started, lane: "a", label: "1A action"),
            TraceEvent(kind: .completed, lane: "a", label: "1A action"),
        ]
        let steps = buildTrace(events)
        #expect(steps.count == 2)
        #expect(steps[0].command == "setup (prefix)")
        #expect(steps[1].command == "1A action (completed)")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test
    func `Failure step carries the invariant name`() {
        let events: [TraceEvent] = [
            TraceEvent(kind: .started, lane: "a", label: "1A increment"),
            TraceEvent(kind: .failed(message: "matchesModel"), lane: "a", label: "1A increment"),
        ]
        let steps = buildTrace(events)
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
    @Test
    func `Command name containing colons does not break parsing`() {
        let events: [TraceEvent] = [
            TraceEvent(kind: .started, lane: "a", label: "1A reset(mode:forced)"),
            TraceEvent(kind: .completed, lane: "a", label: "1A reset(mode:forced)"),
        ]
        let steps = buildTrace(events)
        #expect(steps.count == 1)
        #expect(steps[0].command == "1A reset(mode:forced) (completed)")
    }
}
