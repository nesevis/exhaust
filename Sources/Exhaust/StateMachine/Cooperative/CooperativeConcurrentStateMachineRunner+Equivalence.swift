// The equivalence judgement for task-based runs.
//
// A spec's invariants are claims that hold whatever order the commands ran in, and the drain loop checks them at every point it can. An equivalence is the other kind of claim: what "the same result" means when the order can vary. Judging it needs a sequential run to compare against, which is what this file adds around `drainSchedule`.
//
// The whole judgement is deterministic and replayable from the seed, so it works as the property function during reduction: the schedule is generated input, the replays are fresh instances, and the interleaving search walks the same orderings every time.
import ExhaustCore

// MARK: - Drain and Judge

/// Drains a tagged command sequence and, for a spec that defines an equivalence, judges the drained run against a sequential replay.
///
/// The judgement runs only when the drain itself came back clean. A probe that already broke an invariant or threw has its counterexample; asking whether some order would explain it answers a question nobody asked.
///
/// Three outcomes are possible past that point. The reference replay of the same commands can break an invariant on its own, which makes the sequence a counterexample that needs no interleaving at all. The equivalence can accept the run, which ends the judgement. Or the equivalence can reject it, and the interleaving search decides whether any valid order would have produced what the lanes observed: one that does makes the run linearizable and the rejection a false alarm from comparing against a single fixed order, and none makes it a counterexample carrying the command whose response no order reproduces.
///
/// Repetition has no place here, unlike a thread-based run. The interleaving is generated input rather than whatever the OS chose, so running the same probe again explores nothing.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
func drainAndJudge<Spec: AsyncStateMachineSpec>(
    taggedCommands: [(ScheduleMarker, Spec.Command)],
    setupStep: Spec.SetupStep?,
    specInit: () -> Spec,
    concurrencyLevel: Int,
    recordTrace: Bool,
    idleTimeoutMilliseconds: Int = 1000,
    searchAbandonments: UnsafeSendableBox<Int>? = nil
) -> ConcurrentExecutionResult<Spec> {
    // The instance the lanes ran on is caught here rather than carried on the result. An equivalence is a question asked of that instance, but the verdict outlives the judgement, and a verdict holding a spec keeps it (and anything its commands suspended on) alive for as long as a caller keeps the result.
    let concurrentSpec = UnsafeSendableBox<Spec?>(nil)
    let drained = drainSchedule(
        taggedCommands: taggedCommands,
        setupStep: setupStep,
        specInit: {
            let spec = specInit()
            concurrentSpec.value = spec
            return spec
        },
        concurrencyLevel: concurrencyLevel,
        recordTrace: recordTrace,
        idleTimeoutMilliseconds: idleTimeoutMilliseconds
    )
    guard Spec.hasEquivalence,
          drained.passed,
          drained.timedOut == false,
          let judgedSpec = concurrentSpec.value
    else {
        return drained
    }
    return judgeEquivalence(
        drained,
        taggedCommands: taggedCommands,
        setupStep: setupStep,
        concurrentSpec: judgedSpec,
        recordTrace: recordTrace,
        idleTimeoutMilliseconds: idleTimeoutMilliseconds,
        searchAbandonments: searchAbandonments
    )
}

// MARK: - Judgement

/// What a run turned out to be once its equivalence was consulted.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private enum EquivalenceVerdict {
    /// Some valid order produces an equivalent result, so the run stands as observed.
    case equivalent
    /// The interleaving search spent its replay budget before reaching a verdict. Passes the probe and counts against the run's tally, so a configuration whose searches never finish is reported rather than mistaken for a clean run.
    case abandoned
    /// A sequential replay of the same commands failed on its own, so the sequence is a counterexample without any interleaving.
    case sequentiallyReproducible(message: String, symptomKind: String)
    /// No valid order produces what the lanes observed.
    case notLinearizable(witness: ResponseWitness?, failureDescription: String?)
}

/// The failure a task-based run reports when no valid order produces an equivalent result.
///
/// Exists so the symptom kind carries a type name like every other failure's. The `time:` mode's fault inventory keys its clusters on that string, so an equivalence violation has to be nameable there without being spelled as a bare literal at the reporting site.
struct StateMachineEquivalenceFailure: Error, Sendable {
    /// The spec's own account of the divergence, when it gave one.
    let failureDescription: String?
}

/// Compares a drained run against a sequential replay, and on a mismatch asks whether any valid order explains it.
///
/// The async work runs inside one Task on a single-lane executor drained by the caller's thread, the same bridge the sequential oracle uses: the drain loop's polling stays off the cooperative pool, and one bridge covers the replay, the comparison, and the search rather than paying a round trip for each. A bridge that stalls leaves the run inconclusive, which is how every other stall in this runner is treated — a timed-out probe never manufactures a counterexample.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private func judgeEquivalence<Spec: AsyncStateMachineSpec>(
    _ drained: ConcurrentExecutionResult<Spec>,
    taggedCommands: [(ScheduleMarker, Spec.Command)],
    setupStep: Spec.SetupStep?,
    concurrentSpec: Spec,
    recordTrace: Bool,
    idleTimeoutMilliseconds: Int,
    searchAbandonments: UnsafeSendableBox<Int>?
) -> ConcurrentExecutionResult<Spec> {
    let partition = LanePartition(markers: taggedCommands.map(\.0))
    let prefixCommands = partition.prefixIndices.map { taggedCommands[$0].1 }
    // The reference order is the prefix followed by the lane commands grouped by ascending lane, which is the one fixed order the equivalence is asked about. Thread-based runs replay the same order, so "the reference order" means one thing in both modes.
    let referenceCommands = partition.concurrentIndices.map { taggedCommands[$0].1 }
    let laneResponses = drained.laneResponses

    let verdict = UnsafeSendableBox(EquivalenceVerdict.equivalent)
    let done = UnsafeSendableBox(false)
    let runQueue = RunQueue(laneCount: 1)
    let executor = LaneExecutor(lane: LaneID(index: 0), runQueue: runQueue)
    nonisolated(unsafe) let judgedSpec = concurrentSpec

    Task(executorPreference: executor) { @Sendable [verdict, done] in
        verdict.value = await judge(
            concurrentSpec: judgedSpec,
            setupStep: setupStep,
            prefixCommands: prefixCommands,
            referenceCommands: referenceCommands,
            laneResponses: laneResponses
        )
        done.value = true
    }

    guard ScheduleDrain.drainUntilDone(
        done,
        runQueue: runQueue,
        executor: executor,
        idleTimeoutMilliseconds: idleTimeoutMilliseconds
    ) == .completed else {
        var inconclusive = drained
        inconclusive.timedOut = true
        return inconclusive
    }

    switch verdict.value {
        case .equivalent:
            return drained
        case .abandoned:
            searchAbandonments?.value += 1
            return drained
        case let .sequentiallyReproducible(message, symptomKind):
            var failed = drained
            failed.passed = false
            failed.failureSymptomKind = symptomKind
            failed.judgementDescription = "A sequential replay of these commands fails on its own: \(message)"
            failed.failureDescription = recordTrace ? concurrentSpec.failureDescription() : nil
            return failed
        case let .notLinearizable(witness, failureDescription):
            var failed = drained
            failed.passed = false
            failed.failureSymptomKind = String(describing: StateMachineEquivalenceFailure.self)
            failed.judgementDescription = "No valid order produces an equivalent result."
            failed.linearizabilityWitness = witness
            failed.failureDescription = recordTrace ? failureDescription : nil
            return failed
    }
}

/// Runs the reference replay, the equivalence comparison, and the interleaving search in that order, stopping at the first one that decides the run.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private func judge<Spec: AsyncStateMachineSpec>(
    concurrentSpec: Spec,
    setupStep: Spec.SetupStep?,
    prefixCommands: [Spec.Command],
    referenceCommands: [Spec.Command],
    laneResponses: [[ObservedResponse<Spec.Command>]]
) async -> EquivalenceVerdict {
    let (referenceSpec, referenceSetupError) = await Spec.makeSpec(setupStep: setupStep)
    if let referenceSetupError {
        return .sequentiallyReproducible(
            message: "\(referenceSetupError)",
            symptomKind: String(describing: type(of: referenceSetupError))
        )
    }
    // One command at a time, so the spec is settled after each and an invariant has a state to judge. A failure here needs no interleaving to reproduce, which makes it a verdict on the sequence rather than a question about ordering.
    for command in prefixCommands + referenceCommands {
        if let failure = await runCheckingInvariants(command, on: referenceSpec) {
            return failure
        }
    }

    // The equivalence sees final state and nothing else, so accepting on it alone would pass a history where a command answered something no ordering could have produced. Two lanes that both read a stale register and write it leave a final state some valid ordering also reaches, while the values they returned belong to no ordering at all — exactly the history this mode exists to catch.
    //
    // So the shortcut is taken only when the commands answered nothing: no return values and no skips, which makes final state the whole of what was observed. Otherwise the search decides, because it is the only thing here that compares responses. This is the rule the thread-based runner already applies through its `hasResponseInfo` guard.
    let hasResponseInfo = laneResponses.contains { lane in
        lane.contains { $0.outcome.returnValue != nil || $0.outcome.isSkipped }
    }
    if hasResponseInfo == false, await concurrentSpec.equivalenceCheck(referenceSpec.systemUnderTest) {
        return .equivalent
    }

    // The intervals recorded during the drain are exact rather than measured, so every ordering the search skips is one the run demonstrably could not have taken.
    switch await searchForExplainingOrder(
        concurrentSpec: concurrentSpec,
        setupStep: setupStep,
        prefixCommands: prefixCommands,
        laneResponses: laneResponses,
        replay: .asynchronous
    ) {
        case .linearizable:
            return .equivalent
        case .abandoned:
            return .abandoned
        case let .notLinearizable(witness, failureDescription):
            return .notLinearizable(witness: witness, failureDescription: failureDescription)
    }
}

/// Runs one command on the reference instance and checks its invariants, reporting the verdict a failure implies or nil when the command and the checks passed.
///
/// A command that skips runs nothing and leaves the state where the previous check found it, so its check is skipped with it.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private func runCheckingInvariants<Spec: AsyncStateMachineSpec>(
    _ command: Spec.Command,
    on spec: Spec
) async -> EquivalenceVerdict? {
    do {
        try await spec.run(command)
        try await spec.checkInvariants()
        return nil
    } catch is StateMachineSkip {
        return nil
    } catch let failure as StateMachineCheckFailure {
        return .sequentiallyReproducible(
            message: failure.message ?? "check failed",
            symptomKind: String(describing: type(of: failure))
        )
    } catch {
        return .sequentiallyReproducible(
            message: "\(error)",
            symptomKind: String(describing: type(of: error))
        )
    }
}
