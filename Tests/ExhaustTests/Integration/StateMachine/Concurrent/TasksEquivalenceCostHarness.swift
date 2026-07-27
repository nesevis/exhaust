import Foundation
import Testing
@testable import Exhaust

// Measures what the equivalence judgement costs a task-based run, because every probe that the equivalence rejects pays for a sequential replay and an interleaving search, and reduction runs probes by the hundred.
//
// The fixtures are the worst case on purpose: the commands overwrite each other so nothing commutes, every command suspends inside its read-modify-write so every interval overlaps every other, and the equivalence compares final state so almost every interleaving is rejected and almost every probe reaches the search. Three spec types differ in one thing each — whether an equivalence is declared, and whether commands answer with a value — so a difference between their runs is the price of that one thing.
//
// Left disabled because these produce numbers, not verdicts, and the largest shapes take tens of seconds. Remove the trait on a test to run it.

@Suite("Tasks equivalence cost", .serialized, .tags(.stateMachine))
struct TasksEquivalenceCostHarness {
    /// What one probe costs once the equivalence rejects it and the search has to run.
    ///
    /// Every command in these schedules suspends inside its read-modify-write, so every interval overlaps every other and the search's real-time pruning has nothing to cut. That is the worst case for the search space: a schedule of commands that do not overlap forces its own ordering and the search stays near-linear.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Cost of one judged probe against the drain alone", .disabled("Measurement harness; remove this trait to produce numbers"))
    func costOfOneJudgedProbeAgainstTheDrainAlone() {
        print("lanes x per-lane   drain only    drain + judgement   ratio")
        for lanes in [2, 3] {
            for perLane in [2, 3, 4, 6] {
                let taggedCommands = allBumpSchedule(lanes: lanes, perLane: perLane)
                let drainOnly = timePerProbe(repetitions: 20) {
                    _ = drainSchedule(
                        taggedCommands: taggedCommands,
                        setupStep: nil,
                        specInit: { UnjudgedRegisterSpec() },
                        concurrencyLevel: lanes,
                        recordTrace: false
                    )
                }
                let judged = timePerProbe(repetitions: 20) {
                    _ = drainAndJudge(
                        taggedCommands: taggedCommands,
                        setupStep: nil,
                        specInit: { JudgedRegisterSpec() },
                        concurrencyLevel: lanes,
                        recordTrace: false
                    )
                }
                // Confirms the probe really did fail, so the number above is the cost of an exhausted search rather than an early accept.
                let verdict = drainAndJudge(
                    taggedCommands: taggedCommands,
                    setupStep: nil,
                    specInit: { JudgedRegisterSpec() },
                    concurrencyLevel: lanes,
                    recordTrace: false
                )
                print(
                    "\(lanes) x \(perLane) (\(lanes * perLane) commands)   "
                        + "\(String(format: "%8.0f", drainOnly)) us   "
                        + "\(String(format: "%12.0f", judged)) us   "
                        + "\(String(format: "%5.1f", judged / max(drainOnly, 0.001)))x   "
                        + (verdict.passed ? "accepted" : "rejected")
                )
            }
        }
    }

    /// The same schedules with commands that answer nothing, which is where the search has the least to prune on.
    ///
    /// A command that returns a value lets the search reject an ordering at the first response that does not match, usually within a step or two. With nothing returned, the only thing that can reject an ordering is the equivalence at the end of it, so the search replays whole orderings and the replay budget is what stops it.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Cost of one judged probe whose commands answer nothing", .disabled("Measurement harness; remove this trait to produce numbers"))
    func costOfOneJudgedProbeWhoseCommandsAnswerNothing() {
        print("lanes x per-lane   drain only    drain + judgement   ratio")
        for lanes in [2, 3] {
            for perLane in [2, 3, 4] {
                let taggedCommands = allBumpSchedule(lanes: lanes, perLane: perLane)
                let drainOnly = timePerProbe(repetitions: 2) {
                    _ = drainSchedule(
                        taggedCommands: taggedCommands,
                        setupStep: nil,
                        specInit: { VoidRegisterSpec() },
                        concurrencyLevel: lanes,
                        recordTrace: false
                    )
                }
                let judged = timePerProbe(repetitions: 2) {
                    _ = drainAndJudge(
                        taggedCommands: taggedCommands,
                        setupStep: nil,
                        specInit: { VoidRegisterSpec() },
                        concurrencyLevel: lanes,
                        recordTrace: false
                    )
                }
                let verdict = drainAndJudge(
                    taggedCommands: taggedCommands,
                    setupStep: nil,
                    specInit: { VoidRegisterSpec() },
                    concurrencyLevel: lanes,
                    recordTrace: false
                )
                print(
                    "\(lanes) x \(perLane) (\(lanes * perLane) commands)   "
                        + "\(String(format: "%8.0f", drainOnly)) us   "
                        + "\(String(format: "%12.0f", judged)) us   "
                        + "\(String(format: "%5.1f", judged / max(drainOnly, 0.001)))x   "
                        + (verdict.passed ? "accepted" : "rejected")
                )
            }
        }
    }

    /// What a whole run costs when every probe is judged: discovery to the first counterexample, then reduction, against the deadline reduction is allowed.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Wall clock of a judged run through discovery and reduction", .disabled("Measurement harness; remove this trait to produce numbers"))
    func wallClockOfAJudgedRunThroughDiscoveryAndReduction() async {
        print("reduction deadline floor: \(FuzzTunables.specReductionDeadlineNanoseconds / 1_000_000) ms")
        print("search replay budget:     \(PreemptiveReduction.linearizabilitySearchReplayBudget) replays")
        for lanes in [ConcurrencyLevel.two, .three] {
            for commandLimit in [8, 16, 32] {
                let cost = await measure(JudgedRegisterSpec.self, lanes: lanes, commandLimit: commandLimit)
                print("lanes=\(lanes.rawValue) commandLimit=\(commandLimit): \(cost)")
            }
        }
    }
}

// MARK: - Measurement

/// Microseconds per call, averaged over `repetitions`.
private func timePerProbe(repetitions: Int, _ body: () -> Void) -> Double {
    let clock = ContinuousClock()
    let start = clock.now
    for _ in 0 ..< repetitions {
        body()
    }
    let elapsed = clock.now - start
    let microseconds = Double(elapsed.components.seconds) * 1_000_000
        + Double(elapsed.components.attoseconds) / 1e12
    return microseconds / Double(repetitions)
}

/// A schedule whose every command suspends inside its read-modify-write, so the drain interleaves all of them and no interval precedes another.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private func allBumpSchedule(lanes: Int, perLane: Int) -> [(ScheduleMarker, RegisterCommand)] {
    var schedule: [(ScheduleMarker, RegisterCommand)] = []
    for round in 0 ..< perLane {
        _ = round
        for lane in 1 ... lanes {
            schedule.append((ScheduleMarker(rawValue: UInt8(lane)), .bumpStored))
        }
    }
    return schedule
}

private struct RunCost: CustomStringConvertible {
    var milliseconds: Double
    var propertyInvocations: Int
    var reductionInvocations: Int
    var reducedCommandCount: Int?

    var description: String {
        let reduced = reducedCommandCount.map { "reduced to \($0) commands" } ?? "no counterexample"
        return "\(String(format: "%7.1f", milliseconds)) ms total, \(propertyInvocations) probes, \(reductionInvocations) reduction probes, \(reduced)"
    }
}

/// Runs one spec type through the whole task-based pipeline and reports what it cost.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private func measure<Spec: AsyncStateMachineSpec>(
    _: Spec.Type,
    lanes: ConcurrencyLevel,
    commandLimit: Int
) async -> RunCost {
    nonisolated(unsafe) var report: ExhaustReport?
    let clock = ContinuousClock()
    let start = clock.now
    let result = await __ExhaustRuntime.__runStateMachineConcurrent(
        Spec.self,
        settings: [
            .parallelize(lanes: lanes),
            .commandLimit(commandLimit),
            .budget(.custom(screening: 0, sampling: 200)),
            .suppress(.all),
            .onReport { report = $0 },
        ]
    )
    let elapsed = clock.now - start
    return RunCost(
        milliseconds: Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15,
        propertyInvocations: report?.propertyInvocations ?? 0,
        reductionInvocations: report?.reductionInvocations ?? 0,
        reducedCommandCount: result?.commands.count
    )
}

// MARK: - Specs

/// The judged half of the comparison: overwriting commands that answer with what they replaced, and an equivalence over final state that almost every interleaving fails.
private final class JudgedRegisterSpec: AsyncStateMachineSpec {
    typealias Command = RegisterCommand
    typealias SystemUnderTest = SuspendingRegister

    var lastWritten = 0
    var register = SuspendingRegister()

    static var hasEquivalence: Bool {
        true
    }

    static var commandGenerator: ReflectiveGenerator<Command> {
        registerCommandGenerator
    }

    var systemUnderTest: SuspendingRegister {
        register
    }

    @discardableResult
    func run(_ command: Command) async throws -> CommandResponse {
        let replaced = try await runRegisterCommand(command, register: register, lastWritten: &lastWritten)
        return CommandResponse(commandDescription: command.description, returnValue: replaced)
    }

    func checkInvariants() async throws {}

    func equivalenceCheck(_ sequentialResult: SuspendingRegister) async -> Bool {
        register.value == sequentialResult.value
    }

    func failureDescription() -> String? {
        "register: \(register.value)"
    }

    init() {}
}

/// The unjudged half: the same commands, the same system under test, no equivalence declared. Its runs measure the drain alone.
private final class UnjudgedRegisterSpec: AsyncStateMachineSpec {
    typealias Command = RegisterCommand
    typealias SystemUnderTest = SuspendingRegister

    var lastWritten = 0
    var register = SuspendingRegister()

    static var commandGenerator: ReflectiveGenerator<Command> {
        registerCommandGenerator
    }

    var systemUnderTest: SuspendingRegister {
        register
    }

    @discardableResult
    func run(_ command: Command) async throws -> CommandResponse {
        let replaced = try await runRegisterCommand(command, register: register, lastWritten: &lastWritten)
        return CommandResponse(commandDescription: command.description, returnValue: replaced)
    }

    func checkInvariants() async throws {}

    func equivalenceCheck(_ sequentialResult: SuspendingRegister) async -> Bool {
        register.value == sequentialResult.value
    }

    func failureDescription() -> String? {
        "register: \(register.value)"
    }

    init() {}
}

/// The judged spec with one difference: its commands answer nothing, so the search cannot reject an ordering before it has replayed the whole of it.
private final class VoidRegisterSpec: AsyncStateMachineSpec {
    typealias Command = RegisterCommand
    typealias SystemUnderTest = SuspendingRegister

    var lastWritten = 0
    var register = SuspendingRegister()

    static var hasEquivalence: Bool {
        true
    }

    static var commandGenerator: ReflectiveGenerator<Command> {
        registerCommandGenerator
    }

    var systemUnderTest: SuspendingRegister {
        register
    }

    @discardableResult
    func run(_ command: Command) async throws -> CommandResponse {
        _ = try await runRegisterCommand(command, register: register, lastWritten: &lastWritten)
        return CommandResponse(commandDescription: command.description, returnValue: nil)
    }

    func checkInvariants() async throws {}

    func equivalenceCheck(_ sequentialResult: SuspendingRegister) async -> Bool {
        register.value == sequentialResult.value
    }

    func failureDescription() -> String? {
        "register: \(register.value)"
    }

    init() {}
}

// MARK: - Supporting Types

private enum RegisterCommand: CustomStringConvertible, Sendable {
    case store(value: Int)
    case bumpStored

    var description: String {
        switch self {
            case let .store(value):
                "store(value: \(value))"
            case .bumpStored:
                "bumpStored"
        }
    }
}

/// A register whose write suspends after reading, so the drain loop can interleave inside a read-modify-write. Overwrites do not commute, which is what keeps the equivalence rejecting.
private final class SuspendingRegister: @unchecked Sendable, CustomDebugStringConvertible {
    private var storedValue = 0

    var value: Int {
        storedValue
    }

    var debugDescription: String {
        "SuspendingRegister(value: \(storedValue))"
    }

    /// Writes `value` and answers with what it replaced.
    func store(_ value: Int) -> Int {
        let replaced = storedValue
        storedValue = value
        return replaced
    }

    /// Reads, suspends, then writes one more than it read, so an interleaving here loses an update.
    func bump() async -> Int {
        let current = storedValue
        await Task.yield()
        storedValue = current + 1
        return current
    }
}

// MARK: - Helpers

private let registerCommandGenerator: ReflectiveGenerator<RegisterCommand> = .oneOf(weighted:
    (2, #gen(.int(in: 1 ... 9)) { value in RegisterCommand.store(value: value) }),
    (1, .just(RegisterCommand.bumpStored)))

/// Runs one register command against both the model and the register, answering with the value it replaced.
private func runRegisterCommand(
    _ command: RegisterCommand,
    register: SuspendingRegister,
    lastWritten: inout Int
) async throws -> Int {
    switch command {
        case let .store(value):
            lastWritten = value
            return register.store(value)
        case .bumpStored:
            lastWritten += 1
            return await register.bump()
    }
}
