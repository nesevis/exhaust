import Foundation
import IssueReporting
import Testing
@testable import Exhaust

// A task-based spec that defines an equivalence gets its runs judged against a sequential replay: the replay's own invariants first, then the equivalence, then the interleaving search when the equivalence rejects. Every schedule below is hand-built, so each judgement runs on a known interleaving instead of whichever one a search happens to reach.
//
// The specs are written out instead of declared with `@StateMachine` because the macro still refuses to synthesize an equivalence outside `.threads`. They implement exactly the surface the runner calls.

@Suite("Tasks equivalence judgement", .serialized, .tags(.stateMachine))
struct TasksEquivalenceTests {
    /// The accepting case. The lanes run in the same order the reference replay uses, so the two agree and the judgement ends at the comparison.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("A run the equivalence accepts passes")
    func aRunTheEquivalenceAcceptsPasses() {
        let taggedCommands: [(ScheduleMarker, LastWriteRegisterSpec.Command)] = [
            (ScheduleMarker(rawValue: 1), .store(value: 1)),
            (ScheduleMarker(rawValue: 2), .store(value: 2)),
        ]
        let result = drainAndJudge(
            taggedCommands: taggedCommands,
            setupStep: nil,
            specInit: { LastWriteRegisterSpec() },
            concurrencyLevel: 2,
            recordTrace: true
        )

        #expect(result.passed)
        #expect(result.judgementDescription == nil, "An accepted run owes the report no explanation")
    }

    /// The equivalence compares against one fixed order, and the lanes did not run in it. Linearizability is the authority: the search finds the order the lanes actually took, reproduces the observation, and the rejection turns out to be an artefact of the comparison rather than a defect.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("A run the equivalence rejects passes when some valid order explains it")
    func aRunTheEquivalenceRejectsPassesWhenSomeValidOrderExplainsIt() {
        // Lane b is scheduled first and lane a second, so the register ends at 1. The reference order runs lane a first and ends at 2, which the equivalence reads as a divergence.
        let taggedCommands: [(ScheduleMarker, LastWriteRegisterSpec.Command)] = [
            (ScheduleMarker(rawValue: 2), .store(value: 2)),
            (ScheduleMarker(rawValue: 1), .store(value: 1)),
        ]
        let result = drainAndJudge(
            taggedCommands: taggedCommands,
            setupStep: nil,
            specInit: { LastWriteRegisterSpec() },
            concurrencyLevel: 2,
            recordTrace: true
        )

        #expect(result.passed, "Storing 2 then 1 is a valid order that produces exactly what the lanes observed")
        #expect(result.judgementDescription == nil)
    }

    /// The failing case, and the one the mode exists for. Both increments read the same value, so the counter ends one short of every sequential ordering of the same commands, and the search finds no order that explains it.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("A run no valid order explains is reported as a failure")
    func aRunNoValidOrderExplainsIsReportedAsAFailure() throws {
        // Lane a suspends inside its read-modify-write and lane b is drained into that window, so both read zero and one update is lost.
        let taggedCommands: [(ScheduleMarker, RacyCounterSpec.Command)] = [
            (ScheduleMarker(rawValue: 1), .increment),
            (ScheduleMarker(rawValue: 2), .increment),
        ]
        let result = drainAndJudge(
            taggedCommands: taggedCommands,
            setupStep: nil,
            specInit: { RacyCounterSpec() },
            concurrencyLevel: 2,
            recordTrace: true
        )

        #expect(result.passed == false, "Two increments that both read zero leave the counter at 1, which no ordering of two increments produces")
        #expect(result.timedOut == false)
        let explanation = try #require(result.judgementDescription)
        #expect(explanation.contains("No valid order"), "The report has to say why a run whose own execution came back clean is a failure")
        #expect(result.failureSymptomKind == "StateMachineEquivalenceFailure")
    }

    /// An invariant is a claim that holds whatever order the commands ran in, so the reference replay is entitled to judge it. Here the claim holds in the order the lanes took and breaks in the reference order, which makes the sequence a counterexample that reproduces without any interleaving.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("An invariant that fails on the reference replay fails a run whose drain came back clean")
    func anInvariantThatFailsOnTheReferenceReplayFailsARunWhoseDrainCameBackClean() throws {
        // The schedule appends 1 then 2, which is ascending. The reference order runs lane a first, appending 2 then 1, which is not.
        let taggedCommands: [(ScheduleMarker, AscendingLogSpec.Command)] = [
            (ScheduleMarker(rawValue: 2), .append(value: 1)),
            (ScheduleMarker(rawValue: 1), .append(value: 2)),
        ]
        let result = drainAndJudge(
            taggedCommands: taggedCommands,
            setupStep: nil,
            specInit: { AscendingLogSpec() },
            concurrencyLevel: 2,
            recordTrace: true
        )

        #expect(result.passed == false)
        let explanation = try #require(result.judgementDescription)
        #expect(explanation.contains("sequential replay"), "A failure that needs no interleaving should say so")
    }

    /// A spec that defines no equivalence pays for none of this: no replay, no comparison, no search. Its invariants are the whole judgement.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("A spec with no equivalence is never asked for one")
    func aSpecWithNoEquivalenceIsNeverAskedForOne() {
        let taggedCommands: [(ScheduleMarker, UnjudgedCounterSpec.Command)] = [
            (ScheduleMarker(rawValue: 1), .increment),
            (ScheduleMarker(rawValue: 2), .increment),
        ]
        let result = drainAndJudge(
            taggedCommands: taggedCommands,
            setupStep: nil,
            specInit: { UnjudgedCounterSpec() },
            concurrencyLevel: 2,
            recordTrace: true
        )

        #expect(result.passed, "The same lost update, with nothing declared that could notice it")
        #expect(UnjudgedCounterSpec.equivalenceCallCount.value == 0, "The runner must not consult an equivalence a spec did not declare")
    }

    /// A spec that declares an equivalence takes the thread-based default rather than the estimate-driven one, because its probes pay for a search whose cost grows multinomially in the sequence length. A spec without one keeps the estimate, where a longer sequence costs one longer drain.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("An equivalence lowers the default command limit to the thread-based one")
    func anEquivalenceLowersTheDefaultCommandLimitToTheThreadBasedOne() {
        let commandGen = AscendingLogSpec.commandGenerator.gen
        let screeningBudget = 100_000
        let judged = __ExhaustRuntime.defaultTasksCommandLimit(
            hasEquivalence: true,
            commandGen: commandGen,
            screeningBudget: screeningBudget
        )
        let unjudged = __ExhaustRuntime.defaultTasksCommandLimit(
            hasEquivalence: false,
            commandGen: commandGen,
            screeningBudget: screeningBudget
        )

        #expect(judged == PreemptiveReduction.defaultCommandLimit)
        #expect(judged == 10, "The thread-based default, pinned here so lowering it stays a deliberate change")
        // Without an equivalence the limit is still whatever the screening estimate affords, capped at 40. Asserting the estimate rather than a number keeps this independent of how the estimate is computed.
        #expect(
            unjudged == min(
                __ExhaustRuntime.estimateCommandLimit(commandGen: commandGen, screeningBudget: UInt64(screeningBudget)),
                40
            )
        )
    }

    /// The interleaving-space warning exists because a search too large for its budget is abandoned, and an abandoned search passes its probe. Only a spec that declares an equivalence runs a search under task-based execution, so only one of these two configurations has anything to warn about.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("The interleaving-space warning fires for an equivalence-bearing spec and is silent without one")
    func theInterleavingSpaceWarningFiresForAnEquivalenceBearingSpecAndIsSilentWithoutOne() async {
        let judged = CapturingIssueReporter()
        await withIssueReporters([judged]) {
            _ = await __ExhaustRuntime.__runStateMachineConcurrent(
                RacyCounterSpec.self,
                settings: [
                    .parallelize(lanes: .two),
                    .commandLimit(24),
                    .budget(.custom(screening: 0, sampling: 0)),
                    .suppress(.all),
                ]
            )
        }
        #expect(
            judged.warnings.contains { $0.contains("interleaving") },
            "24 commands across two lanes is millions of orderings, which the search cannot finish inside its budget"
        )

        let unjudged = CapturingIssueReporter()
        await withIssueReporters([unjudged]) {
            _ = await __ExhaustRuntime.__runStateMachineConcurrent(
                UnjudgedCounterSpec.self,
                settings: [
                    .parallelize(lanes: .two),
                    .commandLimit(24),
                    .budget(.custom(screening: 0, sampling: 0)),
                    .suppress(.all),
                ]
            )
        }
        #expect(
            unjudged.warnings.contains { $0.contains("interleaving") } == false,
            "Nothing searches without an equivalence, so the search space is not a cost this spec pays"
        )
    }

    /// An abandoned search passes its probe, so a run whose searches all ran out of budget reports success while having judged nothing. The count is the only thing separating that from a clean run, which is why it warns instead of writing to the log.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("The abandonment warning fires once a search has been abandoned and is silent otherwise")
    func theAbandonmentWarningFiresOnceASearchHasBeenAbandonedAndIsSilentOtherwise() {
        let firing = CapturingIssueReporter()
        withIssueReporters([firing]) {
            warnIfSearchesWereAbandoned(
                abandonedSearches: 1,
                totalProbes: 200,
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
        }
        #expect(firing.warnings.count == 1)
        #expect(firing.warnings.first?.contains("Abandoned the interleaving search on 1 of 200 probes") == true)

        let silent = CapturingIssueReporter()
        withIssueReporters([silent]) {
            warnIfSearchesWereAbandoned(
                abandonedSearches: 0,
                totalProbes: 200,
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
        }
        #expect(silent.warnings.isEmpty)
    }
}

// MARK: - Specs

/// A register whose commands overwrite each other, so the order the lanes ran in decides the result. Nothing here is order-independent, so the spec declares no invariants and states its claim as an equivalence.
private final class LastWriteRegisterSpec: AsyncStateMachineSpec {
    enum Command: CustomStringConvertible, Sendable {
        case store(value: Int)

        var description: String {
            switch self {
                case let .store(value):
                    "store(value: \(value))"
            }
        }
    }

    typealias SystemUnderTest = Register

    var lastWritten = 0
    var register = Register()

    static var hasEquivalence: Bool {
        true
    }

    static var commandGenerator: ReflectiveGenerator<Command> {
        .just(Command.store(value: 1))
    }

    var systemUnderTest: Register {
        register
    }

    @discardableResult
    func run(_ command: Command) async throws -> CommandResponse {
        switch command {
            case let .store(value):
                lastWritten = value
                register.store(value)
        }
        return CommandResponse(commandDescription: command.description, returnValue: nil)
    }

    func checkInvariants() async throws {}

    func equivalenceCheck(_ sequentialResult: Register) async -> Bool {
        register.value == sequentialResult.value
    }

    func failureDescription() -> String? {
        "register: \(register.value)"
    }

    init() {}
}

/// A counter whose read-modify-write suspends in the middle, so an interleaving can drop an update. The claim that the counter matches the number of increments depends on the order commands ran in, so it lives in the equivalence.
private final class RacyCounterSpec: AsyncStateMachineSpec {
    enum Command: CustomStringConvertible, Sendable {
        case increment

        var description: String {
            "increment"
        }
    }

    typealias SystemUnderTest = NonAtomicCounter

    var counter = NonAtomicCounter()

    static var hasEquivalence: Bool {
        true
    }

    static var commandGenerator: ReflectiveGenerator<Command> {
        .just(Command.increment)
    }

    var systemUnderTest: NonAtomicCounter {
        counter
    }

    @discardableResult
    func run(_ command: Command) async throws -> CommandResponse {
        switch command {
            case .increment:
                await counter.increment()
        }
        return CommandResponse(commandDescription: command.description, returnValue: nil)
    }

    func checkInvariants() async throws {}

    func equivalenceCheck(_ sequentialResult: NonAtomicCounter) async -> Bool {
        counter.value == sequentialResult.value
    }

    func failureDescription() -> String? {
        "counter: \(counter.value)"
    }

    init() {}
}

/// Claims its log stays ascending, which is an order-dependent claim written where an order-independent one belongs. The reference replay is where that misplacement surfaces.
private final class AscendingLogSpec: AsyncStateMachineSpec {
    enum Command: CustomStringConvertible, Sendable {
        case append(value: Int)

        var description: String {
            switch self {
                case let .append(value):
                    "append(value: \(value))"
            }
        }
    }

    typealias SystemUnderTest = Register

    var appended: [Int] = []
    var register = Register()

    static var hasEquivalence: Bool {
        true
    }

    static var commandGenerator: ReflectiveGenerator<Command> {
        .just(Command.append(value: 1))
    }

    var systemUnderTest: Register {
        register
    }

    @discardableResult
    func run(_ command: Command) async throws -> CommandResponse {
        switch command {
            case let .append(value):
                appended.append(value)
                register.store(value)
        }
        return CommandResponse(commandDescription: command.description, returnValue: nil)
    }

    func checkInvariants() async throws {
        try check(appended == appended.sorted(), "appended \(appended) is not ascending")
    }

    func equivalenceCheck(_ sequentialResult: Register) async -> Bool {
        register.value == sequentialResult.value
    }

    func failureDescription() -> String? {
        "appended: \(appended)"
    }

    init() {}
}

/// The same lost update as ``RacyCounterSpec`` with nothing declared that could notice it. Its equivalence method counts its own calls, so a test can tell whether the runner asked.
private final class UnjudgedCounterSpec: AsyncStateMachineSpec {
    enum Command: CustomStringConvertible, Sendable {
        case increment

        var description: String {
            "increment"
        }
    }

    typealias SystemUnderTest = NonAtomicCounter

    /// Counts equivalence calls across instances, because the runner constructs its own. Reset by the one test that reads it, which the suite serializes.
    static let equivalenceCallCount = UnsafeSendableBox(0)

    var counter = NonAtomicCounter()

    static var commandGenerator: ReflectiveGenerator<Command> {
        .just(Command.increment)
    }

    var systemUnderTest: NonAtomicCounter {
        counter
    }

    @discardableResult
    func run(_ command: Command) async throws -> CommandResponse {
        switch command {
            case .increment:
                await counter.increment()
        }
        return CommandResponse(commandDescription: command.description, returnValue: nil)
    }

    func checkInvariants() async throws {}

    func equivalenceCheck(_ sequentialResult: NonAtomicCounter) async -> Bool {
        Self.equivalenceCallCount.value += 1
        return counter.value == sequentialResult.value
    }

    func failureDescription() -> String? {
        "counter: \(counter.value)"
    }

    init() {}
}

// MARK: - Supporting Types

/// Collects the messages a run reports, so a test can assert which warnings a configuration earns.
private final class CapturingIssueReporter: IssueReporter, @unchecked Sendable {
    private let lock = NSLock()
    private var warningMessages: [String] = []

    var warnings: [String] {
        lock.withLock { warningMessages }
    }

    func reportIssue(
        _ message: @autoclosure () -> String?,
        severity: IssueSeverity,
        fileID _: StaticString,
        filePath _: StaticString,
        line _: UInt,
        column _: UInt
    ) {
        guard severity == .warning else {
            return
        }
        let captured = message() ?? ""
        lock.withLock { warningMessages.append(captured) }
    }
}

/// A register that keeps only the last value written. Overwrites do not commute, which is what makes order matter.
private final class Register: @unchecked Sendable, CustomDebugStringConvertible {
    private var storedValue = 0

    var value: Int {
        storedValue
    }

    var debugDescription: String {
        "Register(value: \(storedValue))"
    }

    func store(_ value: Int) {
        storedValue = value
    }
}
