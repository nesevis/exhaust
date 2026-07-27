import Testing
@testable import Exhaust

// The drain loop records what every command answered, against the lane that ran it, whether or not the run is the one that reports. Nothing reads those responses yet; these pin the recording so the equivalence pipeline that will read them inherits a settled contract.
//
// Every schedule below is hand-built, so the drain order is fixed and the recorded indices are exact rather than probable.

@Suite("Tasks response recording", .serialized, .tags(.stateMachine))
struct TasksResponseRecordingTests {
    /// Each lane owns its own response list, addressed by lane index, and the prefix keeps its own apart from all of them. The `lane` field carries the marker value the schedule used, because that is what the failure report prints beside a command.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Responses are recorded against the lane that ran the command")
    func responsesAreRecordedAgainstTheLaneThatRanTheCommand() {
        let result = drainSchedule(
            taggedCommands: [
                (.prefix, .append(value: 1)),
                (ScheduleMarker(rawValue: 1), .append(value: 2)),
                (ScheduleMarker(rawValue: 2), .append(value: 3)),
                (ScheduleMarker(rawValue: 1), .append(value: 4)),
            ],
            setupStep: nil,
            specInit: { RespondingLogSpec() },
            concurrencyLevel: 2,
            recordTrace: false
        )

        #expect(result.passed, "The log spec has no defect; the drain should not report one")
        #expect(result.laneResponses.count == 2, "One response list per lane, including lanes that never ran")
        #expect(result.prefixResponses.count == 1)
        #expect(result.laneResponses.first?.count == 2)
        #expect(result.laneResponses.last?.count == 1)
        #expect(result.prefixResponses.allSatisfy { $0.lane == ScheduleMarker.prefix.rawValue })
        #expect(result.laneResponses.first?.allSatisfy { $0.lane == 1 } == true)
        #expect(result.laneResponses.last?.allSatisfy { $0.lane == 2 } == true)
        #expect(
            result.laneResponses.allSatisfy { lane in isStrictlyIncreasing(lane.map { $0.interval?.callTime }) },
            "Within a lane the responses must be in drain order"
        )
    }

    /// A command that skips answers nothing, so its outcome has to say so: the linearizability search matches observed skips against replayed skips, and a skip recorded as a void return would look like a command that ran.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("A command that skips records a skipped outcome")
    func aCommandThatSkipsRecordsASkippedOutcome() throws {
        // Lane a is drained first and the log starts empty, so `removeLast` reaches its guard before anything has been appended.
        let result = drainSchedule(
            taggedCommands: [
                (ScheduleMarker(rawValue: 1), .removeLast),
                (ScheduleMarker(rawValue: 2), .append(value: 5)),
            ],
            setupStep: nil,
            specInit: { RespondingLogSpec() },
            concurrencyLevel: 2,
            recordTrace: false
        )

        #expect(result.passed, "A skipped command is not a failure")
        let skipped = try #require(result.laneResponses.first?.first)
        #expect(skipped.outcome.isSkipped)
        #expect(skipped.outcome.returnValue == nil)
        let appended = try #require(result.laneResponses.last?.first)
        #expect(appended.outcome.isSkipped == false)
        #expect(appended.outcome.returnValue as? Int == 1, "The append landed at the first position, the log having stayed empty")
    }

    /// The indices come from one counter shared by the prefix and every lane, ticked once when a body is entered and once when it returns. Every index is therefore distinct, and the whole run uses exactly two per recorded command.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Call and return indices are drawn from one strictly increasing counter")
    func callAndReturnIndicesAreDrawnFromOneStrictlyIncreasingCounter() throws {
        let result = drainSchedule(
            taggedCommands: [
                (.prefix, .append(value: 1)),
                (ScheduleMarker(rawValue: 1), .appendAfterSuspending(value: 2)),
                (ScheduleMarker(rawValue: 2), .append(value: 3)),
                (ScheduleMarker(rawValue: 1), .removeLast),
            ],
            setupStep: nil,
            specInit: { RespondingLogSpec() },
            concurrencyLevel: 2,
            recordTrace: false
        )

        #expect(result.passed)
        let recorded = result.prefixResponses + result.laneResponses.joined()
        #expect(recorded.count == 4, "Every command either returned or skipped, so every command recorded")
        let intervals = try recorded.map { try #require($0.interval) }
        #expect(intervals.allSatisfy { $0.callTime < $0.returnTime }, "A command cannot return before it was called")
        let indices = intervals.flatMap { [$0.callTime, $0.returnTime] }
        #expect(Set(indices).count == indices.count, "Two events must never share an index")
        #expect(Set(indices) == Set(1 ... UInt64(indices.count)), "The counter ticks exactly twice per recorded command")
    }

    /// Two commands overlap when one is parked inside its body while the other runs. The recorded ranges have to show that, because the linearizability search reads them to decide which orderings it may try: a range that contains another leaves both orders open.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("A command parked at a suspension point records a range containing the command drained inside it")
    func aCommandParkedAtASuspensionPointRecordsARangeContainingTheCommandDrainedInsideIt() throws {
        let result = drainSchedule(
            taggedCommands: [
                (ScheduleMarker(rawValue: 1), .appendAfterSuspending(value: 1)),
                (ScheduleMarker(rawValue: 2), .append(value: 2)),
            ],
            setupStep: nil,
            specInit: { RespondingLogSpec() },
            concurrencyLevel: 2,
            recordTrace: false
        )

        #expect(result.passed)
        let parked = try #require(result.laneResponses.first?.first?.interval)
        let inner = try #require(result.laneResponses.last?.first?.interval)
        #expect(parked.callTime < inner.callTime)
        #expect(inner.returnTime < parked.returnTime, "The parked command's range must contain the one drained inside it")
    }

    /// The converse case, and the one the search prunes on: a command that returned before another was called must be ordered first, so its range has to end before the other's begins.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Commands that never overlap record disjoint ranges")
    func commandsThatNeverOverlapRecordDisjointRanges() throws {
        // Neither body suspends, so each lane task runs to completion in the single job the drain loop gives it.
        let result = drainSchedule(
            taggedCommands: [
                (ScheduleMarker(rawValue: 1), .append(value: 1)),
                (ScheduleMarker(rawValue: 2), .append(value: 2)),
            ],
            setupStep: nil,
            specInit: { RespondingLogSpec() },
            concurrencyLevel: 2,
            recordTrace: false
        )

        #expect(result.passed)
        let first = try #require(result.laneResponses.first?.first?.interval)
        let second = try #require(result.laneResponses.last?.first?.interval)
        #expect(first.returnTime < second.callTime, "Lane a completed before lane b was called, and the ranges must say so")
    }
}

// MARK: - Specs

/// A `.tasks` spec whose commands answer with a value, so the recorded responses carry more than completion. `appendAfterSuspending` opens a window the drain loop can run another lane inside, and `removeLast` skips on an empty log.
@StateMachine(.tasks)
final class RespondingLogSpec {
    var appended: [Int] = []
    @SystemUnderTest
    var log: AppendOnlyLog = .init()

    @Invariant
    func matchesModel() -> Bool {
        log.entries == appended
    }

    @Command(weight: 1, .int(in: 1 ... 9))
    func append(value: Int) async throws -> Int {
        appended.append(value)
        return log.append(value)
    }

    @Command(weight: 1, .int(in: 1 ... 9))
    func appendAfterSuspending(value: Int) async throws -> Int {
        // The suspension precedes both updates, so the model and the log never disagree while this lane is parked.
        await Task.yield()
        appended.append(value)
        return log.append(value)
    }

    @Command(weight: 1)
    func removeLast() async throws -> Int {
        guard appended.isEmpty == false else {
            throw skip()
        }
        appended.removeLast()
        return log.removeLast()
    }

    func failureDescription() -> String? {
        "model: \(appended), log: \(log.entries)"
    }
}

// MARK: - Supporting Types

/// A log with no defect under cooperative scheduling: each mutation is one synchronous read-modify-write, which the drain loop cannot interleave inside. ``append(_:)`` answers with the position it wrote, giving each command a response worth recording.
final class AppendOnlyLog: @unchecked Sendable, CustomDebugStringConvertible {
    private var storedEntries: [Int] = []

    var entries: [Int] {
        storedEntries
    }

    var debugDescription: String {
        "AppendOnlyLog(entries: \(storedEntries))"
    }

    /// Appends `value` and answers with its one-based position.
    func append(_ value: Int) -> Int {
        storedEntries.append(value)
        return storedEntries.count
    }

    /// Removes the last entry and answers with it.
    func removeLast() -> Int {
        storedEntries.removeLast()
    }
}

// MARK: - Helpers

private func isStrictlyIncreasing(_ values: [UInt64?]) -> Bool {
    zip(values, values.dropFirst()).allSatisfy { earlier, later in
        guard let earlier, let later else {
            return false
        }
        return earlier < later
    }
}
