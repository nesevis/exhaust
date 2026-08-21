import ExhaustCore
import Foundation
import Testing
@testable import Exhaust

// MARK: - Sequential End-to-End

@Suite("@Setup generator-fed setup", .serialized, .tags(.stateMachine))
struct SetupGeneratorTests {
    @Test("Setup-independent failure reduces the setup to its floor and the commands to one")
    func setupIndependentFailureReducesSetupToFloor() async throws {
        let result = try #require(
            await #execute(
                AlwaysFailingSetupSpec.self,
                mode: .sequential,
                .commandLimit(6),
                .budget(.custom(screening: 0, sampling: 50)),
                .suppress(.issueReporting)
            )
        )
        let setup = try #require(result.setup)
        guard case let .configure(capacity, preload) = setup else {
            Issue.record("Expected a configure setup step, got \(setup)")
            return
        }
        // The failure holds for every setup value, so pass 0 minimizes capacity to its range floor and deletes every preload element.
        #expect(capacity == 1)
        #expect(preload.isEmpty)
        // The command passes run after setup settles and still reduce the sequence.
        #expect(result.commands.count == 1)
    }

    @Test("Setup-dependent failure pins the setup value the failure needs")
    func setupDependentFailurePinsSetupValue() async throws {
        let result = try #require(
            await #execute(
                CapacityGatedSpec.self,
                mode: .sequential,
                .commandLimit(6),
                .budget(.custom(screening: 0, sampling: 300)),
                .suppress(.issueReporting)
            )
        )
        let setup = try #require(result.setup)
        guard case let .configure(capacity) = setup else {
            Issue.record("Expected a configure setup step, got \(setup)")
            return
        }
        // The property only fails at capacity 10 or above, so setup reduction cannot cross that boundary.
        #expect(capacity >= 10)
    }

    @Test("Setup steps render first in the trace with the (setup) suffix and shift command indices")
    func setupStepsRenderFirstInTrace() async throws {
        let result = try #require(
            await #execute(
                AlwaysFailingSetupSpec.self,
                mode: .sequential,
                .commandLimit(6),
                .budget(.custom(screening: 0, sampling: 50)),
                .suppress(.issueReporting)
            )
        )
        let firstStep = try #require(result.trace.first)
        #expect(firstStep.index == 1)
        #expect(firstStep.command.hasSuffix("(setup)"))
        #expect(firstStep.command.hasPrefix("configure("))
        for (offset, step) in result.trace.enumerated() {
            #expect(step.index == offset + 1)
        }
        let commandSteps = result.trace.filter { $0.command.hasSuffix("(setup)") == false }
        #expect(commandSteps.isEmpty == false)
    }

    @Test("The failure header counts the setup step on both sides of the reduction")
    func failureHeaderCountsSetupStep() async throws {
        let result = try #require(
            await #execute(
                AlwaysFailingSetupSpec.self,
                mode: .sequential,
                .commandLimit(6),
                .budget(.custom(screening: 0, sampling: 50)),
                .suppress(.issueReporting)
            )
        )
        let originalCommands = try #require(result.originalCommands)
        let message = renderSequentialFailure(result)
        #expect(message.contains("Command sequence (\(result.commands.count + 1) step"))
        if originalCommands.count > result.commands.count {
            #expect(message.contains("reduced from \(originalCommands.count + 1)):"))
        }
    }

    @Test("A single-step counterexample reports one step rather than one steps")
    func singleStepHeaderIsSingular() {
        let result = StateMachineResult<PlainFailingSpec>(
            commands: [.bump],
            originalCommands: [.bump, .bump, .bump],
            setup: nil,
            trace: [],
            systemUnderTest: nil,
            seed: nil,
            replaySeed: nil,
            discoveryMethod: .randomSampling
        )
        #expect(renderSequentialFailure(result).contains("Command sequence (1 step, reduced from 3):"))
    }

    @Test("The failure header for a zero-setup spec counts commands only")
    func failureHeaderForZeroSetupSpecCountsCommandsOnly() async throws {
        let result = try #require(
            await #execute(
                PlainFailingSpec.self,
                mode: .sequential,
                .commandLimit(4),
                .budget(.custom(screening: 0, sampling: 50)),
                .suppress(.issueReporting)
            )
        )
        let originalCommands = try #require(result.originalCommands)
        let message = renderSequentialFailure(result)
        #expect(message.contains("Command sequence (\(result.commands.count) step"))
        if originalCommands.count > result.commands.count {
            #expect(message.contains("reduced from \(originalCommands.count)):"))
        }
    }

    @Test("A throwing setup fails the run and is attributed to the setup step")
    func throwingSetupFailsTheRun() async throws {
        let result = try #require(
            await #execute(
                ThrowingSetupSpec.self,
                mode: .sequential,
                .commandLimit(4),
                .budget(.custom(screening: 0, sampling: 20)),
                .suppress(.issueReporting)
            )
        )
        let firstStep = try #require(result.trace.first)
        #expect(firstStep.command.hasSuffix("(setup)"))
        guard case .checkFailed = firstStep.outcome else {
            Issue.record("Expected the setup step to carry the failure, got \(firstStep.outcome)")
            return
        }
    }

    @Test("An implicitly unwrapped SUT constructed in setup compiles and passes")
    func implicitlyUnwrappedSUTConstructedInSetup() async {
        // The synthesized `typealias SystemUnderTest` must normalize the property's `ValueBox!` to `ValueBox?`, because Swift rejects the implicitly unwrapped spelling in a typealias. Compiling this spec is the regression; the run confirms setup reaches the instance.
        let result = await #execute(
            ImplicitlyUnwrappedSUTSpec.self,
            mode: .sequential,
            .commandLimit(4),
            .budget(.custom(screening: 0, sampling: 30)),
            .suppress(.issueReporting)
        )
        #expect(result == nil)
    }

    @Test("A zero-setup spec reports nil setup")
    func zeroSetupSpecReportsNilSetup() async throws {
        let result = try #require(
            await #execute(
                PlainFailingSpec.self,
                mode: .sequential,
                .commandLimit(4),
                .budget(.custom(screening: 0, sampling: 50)),
                .suppress(.issueReporting)
            )
        )
        #expect(result.setup == nil)
    }

    @Test("Replay seed reproduces the same setup value")
    func replaySeedReproducesSetup() async throws {
        let first = try #require(
            await #execute(
                CapacityGatedSpec.self,
                mode: .sequential,
                .commandLimit(6),
                .budget(.custom(screening: 0, sampling: 300)),
                .suppress(.issueReporting)
            )
        )
        let replaySeed = try #require(first.replaySeed)
        let replayed = try #require(
            await #execute(
                CapacityGatedSpec.self,
                mode: .sequential,
                .commandLimit(6),
                .replay(.encoded(replaySeed)),
                .suppress(.issueReporting)
            )
        )
        #expect(replayed.setup.map { "\($0)" } == first.setup.map { "\($0)" })
    }
}

// MARK: - Choice-Sequence Compatibility

@Suite("@Setup choice-sequence compatibility", .tags(.stateMachine))
struct SetupChoiceSequenceTests {
    @Test("Zero-setup candidate generator leaves the choice sequence byte-identical")
    func zeroSetupCandidateTreeIsByteIdentical() {
        let sequenceGen = __ExhaustRuntime.taggedSequenceGenerator(
            commandGen: PlainFailingSpec.commandGenerator,
            commandLimit: 6
        )
        let candidateGen = __ExhaustRuntime.specCandidateGenerator(
            PlainFailingSpec.self,
            sequenceGen: sequenceGen
        )

        // Every recorded regression seed for every existing spec depends on this holding at every seed, not at a
        // handful of them, so the seed is the generated value.
        #exhaust(.uint64()) { seed in
            var rawInterpreter = ValueAndChoiceTreeInterpreter(sequenceGen, seed: seed, maxRuns: 1)
            var candidateInterpreter = ValueAndChoiceTreeInterpreter(candidateGen, seed: seed, maxRuns: 1)
            let rawRun = try rawInterpreter.next()
            let candidateRun = try candidateInterpreter.next()
            let (rawValue, rawTree) = try #require(rawRun)
            let (candidate, candidateTree) = try #require(candidateRun)

            #expect(candidate.setupStep == nil)
            #expect(candidate.taggedCommands.map(\.1) == rawValue.map(\.1))
            #expect(ChoiceSequence.flatten(candidateTree) == ChoiceSequence.flatten(rawTree))
        }
    }

    @Test("Extracted setup child is exactly the tree the setup generator materializes standalone")
    func extractedSetupChildMaterializesStandalone() throws {
        let setupGen = try #require(AlwaysFailingSetupSpec.setupGenerator)
        let sequenceGen = __ExhaustRuntime.taggedSequenceGenerator(
            commandGen: AlwaysFailingSetupSpec.commandGenerator,
            commandLimit: 6
        )
        let candidateGen = __ExhaustRuntime.specCandidateGenerator(
            AlwaysFailingSetupSpec.self,
            sequenceGen: sequenceGen
        )

        // Screening builds candidate trees by composition and reduction takes them apart again, so split and
        // compose have to be inverses at every seed rather than at a sample of them.
        #exhaust(.uint64()) { seed in
            var interpreter = ValueAndChoiceTreeInterpreter(candidateGen, seed: seed, maxRuns: 1)
            let run = try interpreter.next()
            let (candidate, tree) = try #require(run)
            let split = try #require(__ExhaustRuntime.splitCandidateTree(tree))

            // Exact materialization of the setup generator against the extracted child must reproduce the candidate's setup step. Pass 0 collapses without this.
            let setupSequence = ChoiceSequence.flatten(split.setupTree)
            let materialized = Materializer.materialize(
                setupGen.gen,
                prefix: setupSequence,
                mode: .exact,
                fallbackTree: split.setupTree
            )
            guard case let .success(step, _, _) = materialized else {
                Issue.record("Exact materialization of the extracted setup child failed for seed \(seed)")
                return
            }
            let candidateStep = try #require(candidate.setupStep)
            #expect("\(step)" == "\(candidateStep)")

            // Recomposition is the inverse of the split, byte-identical as a choice sequence.
            let recomposed = __ExhaustRuntime.composeCandidateTree(
                setupTree: split.setupTree,
                commandTree: split.commandTree
            )
            #expect(ChoiceSequence.flatten(recomposed) == ChoiceSequence.flatten(tree))
        }
    }

    @Test("Screening finds failures on a with-setup spec and the U-seed replay reproduces the same setup")
    func screeningWorksWithSetupAndReplayIsDeterministic() async throws {
        // Screening stage A: the row loop materializes full candidates with the setup subtree drawn from the row counter, so a `U-N` replay must land on the same row with the same setup value.
        let first = try #require(
            await #execute(
                AlwaysFailingSetupSpec.self,
                mode: .sequential,
                .commandLimit(4),
                .budget(.custom(screening: 50, sampling: 0)),
                .suppress(.issueReporting)
            )
        )
        #expect(first.discoveryMethod == .screening)
        let replaySeed = try #require(first.replaySeed)
        #expect(replaySeed.contains("-U"))

        let replayed = try #require(
            await #execute(
                AlwaysFailingSetupSpec.self,
                mode: .sequential,
                .commandLimit(4),
                .replay(.encoded(replaySeed)),
                .suppress(.issueReporting)
            )
        )
        #expect(replayed.discoveryMethod == .screening)
        #expect(replayed.setup.map { "\($0)" } == first.setup.map { "\($0)" })
        // Row determinism: the replay must land on the same row with the same pre-reduction command sequence, or the U-seed is not reproducing what discovery found.
        let firstOriginal = try #require(first.originalCommands)
        let replayedOriginal = try #require(replayed.originalCommands)
        #expect(replayedOriginal.map { "\($0)" } == firstOriginal.map { "\($0)" })
    }

    @Test("A failure in a later tier replays after an earlier tier was cut off by its budget share")
    func laterTierFailureSurvivesEarlierTierTruncation() async throws {
        // The geometry that used to corrupt global row numbering: at commandLimit 10 and screening budget 200, the tiers are length 5 with 150 rows and length 10 with 50. The length-5 tier's saturating stream holds 5 × 2⁵ = 160 points (setup domain × five binary command positions), so its budget share cuts it off mid-stream, and the spec only fails past the fifth command, so the failure lands in the length-10 tier. A global row number would count the 150 truncated rows and land a replay inside the length-5 tier; the tier-addressed seed cannot.
        var capturedReport: ExhaustReport?
        let discovered = try #require(
            await #execute(
                LongSequenceOnlyBugSpec.self,
                mode: .sequential,
                .commandLimit(10),
                .budget(.custom(screening: 200, sampling: 0)),
                .onReport { capturedReport = $0 },
                .suppress(.issueReporting)
            )
        )
        #expect(discovered.discoveryMethod == .screening)
        let replaySeed = try #require(discovered.replaySeed)
        #expect(replaySeed.hasSuffix("L10"), "The failure should come from the length-10 tier, got \(replaySeed)")
        // 150 passing rows from the truncated length-5 tier, then the first length-10 row fails. Any other count means the tier geometry above no longer holds and this test has stopped exercising truncation.
        #expect(capturedReport?.screeningInvocations == 151)

        // A smaller replay budget on purpose: global row numbering would need 151 rows of budget and would spend the whole skip range inside the truncated length-5 tier. The tier-addressed replay rebuilds only the length-10 tier.
        let replayed = try #require(
            await #execute(
                LongSequenceOnlyBugSpec.self,
                mode: .sequential,
                .commandLimit(10),
                .budget(.custom(screening: 50, sampling: 0)),
                .replay(.encoded(replaySeed)),
                .suppress(.issueReporting)
            )
        )
        #expect(replayed.discoveryMethod == .screening)
        #expect(replayed.replaySeed == replaySeed)
        #expect(replayed.setup.map { "\($0)" } == discovered.setup.map { "\($0)" })
        let discoveredOriginal = try #require(discovered.originalCommands)
        let replayedOriginal = try #require(replayed.originalCommands)
        #expect(replayedOriginal.map { "\($0)" } == discoveredOriginal.map { "\($0)" })
    }
}

// MARK: - Concurrent Modes

@Suite("@Setup under concurrent execution models", .serialized, .tags(.stateMachine))
struct SetupConcurrentTests {
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("mode: .tasks passes when the model and the system under test are seeded identically")
    func tasksSpecWithSetupPasses() async {
        let result = await #execute(
            SeededSpec.self,
            mode: .tasks,
            .commandLimit(6),
            .budget(.custom(screening: 0, sampling: 30)),
            .suppress(.issueReporting)
        )
        // If any executor instance missed the setup application, the invariant would flag the divergence immediately.
        #expect(result == nil)
    }

    @Test("mode: .threads passes because every replay instance shares the setup")
    func threadsSpecWithSetupPasses() async {
        let result = await #execute(
            SeededSpec.self,
            mode: .threads,
            .commandLimit(6),
            .budget(.custom(screening: 0, sampling: 30)),
            .suppress(.issueReporting)
        )
        // The equivalence compares the concurrent system under test against fresh sequential replays, and the invariant is judged along those replays. A missed setup on any instance the run constructs (reference, witness, search replays) would diverge and fail.
        #expect(result == nil)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("mode: .tasks reports the setup value the system under test was configured with")
    func tasksSpecReportsSetupValue() async throws {
        let result = try #require(
            await #execute(
                CapacityGatedSpec.self,
                mode: .tasks,
                .commandLimit(6),
                .budget(.custom(screening: 0, sampling: 200)),
                .suppress(.issueReporting)
            )
        )
        let setup = try #require(result.setup)
        guard case let .configure(capacity) = setup else {
            Issue.record("Expected a configure setup step, got \(setup)")
            return
        }
        // The command gates on the SUT's own counter, which only the setup writes to. A run that reached the failing regime at all is proof the setup was applied to the instance the cooperative lanes executed against, and the boundary pins how far setup reduction may travel.
        #expect(capacity >= 10)
        // Asserted through the trace rather than `systemUnderTest`: the cooperative drain populates the SUT only on its final return path, so a counterexample that reduces down to the prefix phase reports nil.
        let firstStep = try #require(result.trace.first)
        #expect(firstStep.command.hasSuffix("(setup)"))
        #expect(
            firstStep.command.contains("capacity: \(capacity)"),
            "Trace setup entry and the reported setup value disagree: \(firstStep.command)"
        )
    }

    @Test("mode: .threads attributes a throwing setup to the setup step")
    func threadsThrowingSetupAttributedToSetupStep() async throws {
        let result = try #require(
            await #execute(
                ThrowingSetupSpec.self,
                mode: .threads,
                .commandLimit(4),
                .budget(.custom(screening: 0, sampling: 20)),
                .suppress(.issueReporting)
            )
        )
        // The preemptive backend replays the setup when it builds the result, so the trace row carries the real thrown error rather than a fabricated success.
        let firstStep = try #require(result.trace.first)
        #expect(firstStep.command.hasSuffix("(setup)"))
        guard case .checkFailed = firstStep.outcome else {
            Issue.record("Expected the setup step to carry the failure, got \(firstStep.outcome)")
            return
        }
    }

    @Test("mode: .threads reports the setup value the run rejected")
    func threadsSpecReportsSetupValue() async throws {
        let result = try #require(
            await #execute(
                CapacityGatedSpec.self,
                mode: .threads,
                .commandLimit(6),
                .budget(.custom(screening: 0, sampling: 100)),
                .suppress(.issueReporting)
            )
        )
        let setup = try #require(result.setup)
        guard case let .configure(capacity) = setup else {
            Issue.record("Expected a configure setup step, got \(setup)")
            return
        }
        // The command reads the concurrent spec's own counter, which only the setup writes to, so a failure at all means setup reached the instance this run executed against. Asserted through the trace rather than `systemUnderTest`, which the thread-based backend leaves nil when the smoke phase is what discovers the failure.
        #expect(capacity >= 10)
        let firstStep = try #require(result.trace.first)
        #expect(firstStep.command.hasSuffix("(setup)"))
        #expect(
            firstStep.command.contains("capacity: \(capacity)"),
            "Trace setup entry and the reported setup value disagree: \(firstStep.command)"
        )
    }
}

// MARK: - Test Specs

@StateMachine
private final class AlwaysFailingSetupSpec {
    var capacity = 0
    var preload: [Int] = []
    @SystemUnderTest var box = ValueBox()

    @Setup(.int(in: 1 ... 32), .int(in: 0 ... 9).array(length: 0 ... 4))
    func configure(capacity: Int, preload: [Int]) {
        self.capacity = capacity
        self.preload = preload
        box.value = capacity
    }

    @Command(weight: 1, .int(in: 0 ... 9))
    func boom(value _: Int) throws {
        try check(false, "always fails")
    }

    func failureDescription() -> String? {
        "capacity: \(capacity), preload: \(preload)"
    }
}

/// Fails only past the fifth executed command, so no length-5 screening row can trigger it and a screening failure must come from the length-10 tier. The setup argument exists to give the length-5 tier a 160-point saturating stream (5 × 2⁵), larger than that tier's 150-row share of the standard screening budget.
@StateMachine
private final class LongSequenceOnlyBugSpec {
    var executedCommands = 0
    @SystemUnderTest var counter = ValueBox()

    @Setup(.int(in: 0 ... 4))
    func configure(offset: Int) {
        counter.value = offset
    }

    @Command(weight: 1)
    func tick() throws {
        executedCommands += 1
        counter.value += 1
        try check(executedCommands <= 5, "failed past the fifth command")
    }

    @Command(weight: 1)
    func tock() throws {
        executedCommands += 1
        counter.value -= 1
        try check(executedCommands <= 5, "failed past the fifth command")
    }

    func failureDescription() -> String? {
        "executed: \(executedCommands), counter: \(counter.value)"
    }
}

/// One spec for all three modes, which is what lets the tests below check that `@Setup` reaches every instance a run constructs without a per-mode copy of the spec.
///
/// The command gates on the system under test rather than on a spec-side copy of the capacity, so a failure at all is proof the setup reached the instance the run executed against. No command mutates the counter, which keeps the verdict independent of the interleaving. The equivalence is there because `mode: .threads` requires one; the failure comes from the command's own check in every mode.
@StateMachine
private final class CapacityGatedSpec {
    @SystemUnderTest var counter = LockedCounter()

    @Setup(.int(in: 1 ... 32))
    func configure(capacity: Int) {
        counter.add(capacity)
    }

    @Command(weight: 1)
    func poke() async throws {
        try check(counter.value < 10, "capacity reached the failing regime")
    }

    @Equivalence
    func equivalent(to other: LockedCounter) -> Bool {
        counter.value == other.value
    }

    func failureDescription() -> String? {
        "counter: \(counter.value)"
    }
}

/// One spec for the sequential and thread-based tests. The setup throws before any command runs, so nothing downstream of it distinguishes the modes; the equivalence is there because `mode: .threads` requires one.
@StateMachine
private final class ThrowingSetupSpec {
    @SystemUnderTest var counter = LockedCounter()

    @Setup(.int(in: 0 ... 9))
    func configure(seed _: Int) throws {
        throw PlantedSetupError()
    }

    @Command(weight: 1)
    func touch() {
        _ = counter.value
    }

    @Equivalence
    func equivalent(to other: LockedCounter) -> Bool {
        counter.value == other.value
    }

    func failureDescription() -> String? {
        nil
    }
}

@StateMachine
private final class PlainFailingSpec {
    var count = 0
    @SystemUnderTest var box = ValueBox()

    @Command(weight: 1)
    func bump() throws {
        count += 1
        try check(count < 3, "count reached 3")
    }

    func failureDescription() -> String? {
        "count: \(count)"
    }
}

@StateMachine
private final class ImplicitlyUnwrappedSUTSpec {
    @SystemUnderTest var box: ValueBox!

    @Setup(.int(in: 1 ... 8))
    func configure(start: Int) {
        let box = ValueBox()
        box.value = start
        self.box = box
    }

    @Command(weight: 1)
    func bump() throws {
        box.value += 1
    }

    @Invariant
    func staysPositive() -> Bool {
        box.value > 0
    }

    func failureDescription() -> String? {
        "value: \(box.value)"
    }
}

/// One spec for both concurrent modes, carrying the model and the equivalence together.
///
/// The model is a `LockedCounter` rather than a plain `Int`, which is what makes it shareable: `mode: .threads` runs every lane against this one instance, where an unsynchronised model write would be a data race. Its invariant is checked at quiescence under `mode: .tasks` and in the sequential replays under `mode: .threads`, and a lane that missed the setup would diverge from the model either way.
@StateMachine
private final class SeededSpec {
    var model = LockedCounter()
    @SystemUnderTest var counter = LockedCounter()

    @Setup(.int(in: 1 ... 8))
    func seed(start: Int) {
        model.add(start)
        counter.add(start)
    }

    @Invariant
    func matchesModel() -> Bool {
        counter.value == model.value
    }

    @Command(weight: 1)
    func increment() async throws {
        model.add(1)
        counter.add(1)
    }

    @Equivalence
    func equivalent(to other: LockedCounter) -> Bool {
        counter.value == other.value
    }

    func failureDescription() -> String? {
        "model: \(model.value), counter: \(counter.value)"
    }
}

// MARK: - Supporting Types

private final class ValueBox {
    var value = 0
}

private struct PlantedSetupError: Error {}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func add(_ amount: Int) {
        lock.lock()
        defer { lock.unlock() }
        storage += amount
    }
}

// MARK: - Helpers

/// Re-renders a result the way the sequential backend does, so the assembled failure report can be asserted on while issue reporting stays suppressed.
///
/// A ``StateMachineResult`` does not carry the run's iteration or budget, so the header those two produce is stubbed. Callers here assert on the command-sequence line, never the header.
private func renderSequentialFailure(_ result: StateMachineResult<some StateMachineSpecBase>) -> String {
    __ExhaustRuntime.renderFailure(
        result,
        failureInfo: __ExhaustRuntime.StateMachineFailureInfo(
            originalCommands: result.originalCommands,
            discoveryMethod: result.discoveryMethod,
            iteration: 1,
            budget: ExhaustBudget.standard.samplingBudget
        ),
        failureDescription: nil
    )
}
