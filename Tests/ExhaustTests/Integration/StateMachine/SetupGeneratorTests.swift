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

    @Test("A throwing setup fails the run and is attributed to the setup step")
    func throwingSetupFailsTheRun() async throws {
        let result = try #require(
            await #execute(
                ThrowingSetupSpec.self,
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

    @Test("A zero-setup spec reports nil setup")
    func zeroSetupSpecReportsNilSetup() async throws {
        let result = try #require(
            await #execute(
                PlainFailingSpec.self,
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
                .commandLimit(6),
                .budget(.custom(screening: 0, sampling: 300)),
                .suppress(.issueReporting)
            )
        )
        let replaySeed = try #require(first.replaySeed)
        let replayed = try #require(
            await #execute(
                CapacityGatedSpec.self,
                .commandLimit(6),
                .replay(ReplaySeed(stringLiteral: replaySeed)),
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
                .commandLimit(4),
                .budget(.custom(screening: 50, sampling: 0)),
                .suppress(.issueReporting)
            )
        )
        #expect(first.discoveryMethod == .screening)
        let replaySeed = try #require(first.replaySeed)
        #expect(replaySeed.hasPrefix("U"))

        let replayed = try #require(
            await #execute(
                AlwaysFailingSetupSpec.self,
                .commandLimit(4),
                .replay(ReplaySeed(stringLiteral: replaySeed)),
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
}

// MARK: - Concurrent Modes

@Suite("@Setup under concurrent execution models", .serialized, .tags(.stateMachine))
struct SetupConcurrentTests {
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(".tasks spec with setup passes when model and SUT are seeded identically")
    func tasksSpecWithSetupPasses() async {
        let result = await #execute(
            SeededTasksSpec.self,
            .commandLimit(6),
            .budget(.custom(screening: 0, sampling: 30)),
            .suppress(.issueReporting)
        )
        // If any executor instance missed the setup application, the invariant would flag the divergence immediately.
        #expect(result == nil)
    }

    @Test(".threads spec with setup passes because all replay instances share the setup")
    func threadsSpecWithSetupPasses() async {
        let result = await #execute(
            SeededThreadsSpec.self,
            .commandLimit(6),
            .budget(.custom(screening: 0, sampling: 30)),
            .suppress(.issueReporting)
        )
        // The oracle compares the concurrent SUT against fresh sequential replays. A missed setup on any of the runner's instances (reference, witness, oracle, DFS replays) would diverge and fail.
        #expect(result == nil)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(".tasks spec reports the setup value the SUT was configured with")
    func tasksSpecReportsSetupValue() async throws {
        let result = try #require(
            await #execute(
                CapacityGatedTasksSpec.self,
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

    @Test(".threads spec reports the setup value the oracle rejected")
    func threadsSpecReportsSetupValue() async throws {
        let result = try #require(
            await #execute(
                CapacityGatedThreadsSpec.self,
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
        // The oracle reads the concurrent spec's own counter, which only the setup writes to, so a failure at all means setup reached the instance the preemptive lanes ran against. Asserted through the trace rather than `systemUnderTest`, which the preemptive backend leaves nil when the smoke phase is what discovers the failure.
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

@StateMachine(.sequential)
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

@StateMachine(.sequential)
private final class CapacityGatedSpec {
    var capacity = 0
    @SystemUnderTest var box = ValueBox()

    @Setup(.int(in: 1 ... 32))
    func configure(capacity: Int) {
        self.capacity = capacity
        box.value = capacity
    }

    @Command(weight: 1)
    func poke() throws {
        try check(capacity < 10, "capacity reached the failing regime")
    }

    func failureDescription() -> String? {
        "capacity: \(capacity)"
    }
}

@StateMachine(.sequential)
private final class ThrowingSetupSpec {
    @SystemUnderTest var box = ValueBox()

    @Setup(.int(in: 0 ... 9))
    func configure(seed _: Int) throws {
        throw PlantedSetupError()
    }

    @Command(weight: 1)
    func poke() throws {}

    func failureDescription() -> String? {
        nil
    }
}

@StateMachine(.sequential)
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

@StateMachine(.tasks)
private final class SeededTasksSpec {
    var model = 0
    @SystemUnderTest var counter = LockedCounter()

    @Setup(.int(in: 1 ... 8))
    func seed(start: Int) {
        model = start
        counter.add(start)
    }

    @Invariant
    func matchesModel() -> Bool {
        counter.value == model
    }

    @Command(weight: 1)
    func increment() async throws {
        model += 1
        counter.add(1)
    }

    func failureDescription() -> String? {
        "model: \(model), counter: \(counter.value)"
    }
}

@StateMachine(.threads)
private final class SeededThreadsSpec {
    @SystemUnderTest var counter = LockedCounter()

    @Setup(.int(in: 1 ... 8))
    func seed(start: Int) {
        counter.add(start)
    }

    @Oracle
    func equivalent(to other: LockedCounter) -> Bool {
        counter.value == other.value
    }

    @Command(weight: 1)
    func increment() {
        counter.add(1)
    }

    func failureDescription() -> String? {
        "counter: \(counter.value)"
    }
}

@StateMachine(.tasks)
private final class CapacityGatedTasksSpec {
    @SystemUnderTest var counter = LockedCounter()

    @Setup(.int(in: 1 ... 32))
    func configure(capacity: Int) {
        counter.add(capacity)
    }

    /// Gates on the SUT rather than on a spec-side copy of the capacity, so the command can only fail when the setup reached the instance the lanes execute against. No command mutates the counter, which keeps the verdict independent of the interleaving.
    @Command(weight: 1)
    func poke() async throws {
        try check(counter.value < 10, "capacity reached the failing regime")
    }

    func failureDescription() -> String? {
        "counter: \(counter.value)"
    }
}

@StateMachine(.threads)
private final class CapacityGatedThreadsSpec {
    @SystemUnderTest var counter = LockedCounter()

    @Setup(.int(in: 1 ... 32))
    func configure(capacity: Int) {
        counter.add(capacity)
    }

    /// Deliberately leaves the counter alone: the oracle's verdict then depends only on the setup value, so the failure is deterministic instead of race-dependent.
    @Command(weight: 1)
    func touch() {
        _ = counter.value
    }

    @Oracle
    func equivalent(to other: LockedCounter) -> Bool {
        counter.value < 10 && counter.value == other.value
    }

    func failureDescription() -> String? {
        "counter: \(counter.value)"
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
