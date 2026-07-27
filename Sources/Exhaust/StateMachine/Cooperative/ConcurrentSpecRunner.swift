//
// Executes a tagged command sequence through a cooperative scheduler that deterministically controls interleaving at every `await` boundary. The input is a flat [(ScheduleMarker, Command)] array that encodes both the lane partition AND the interleaving order:
//
//   - ScheduleMarker(rawValue: 0) → prefix: runs sequentially before the concurrent phase (state setup)
//   - ScheduleMarker(rawValue: 1...N) → assigns to lane a...n; array position defines drain order
//
// The array order of non-prefix markers becomes the schedule: when the drain loop needs to pick which lane to advance, it consults the next marker in sequence. This encoding means reduction can simultaneously reduce commands (array deletion) and reduce concurrency (marker minimization toward 0/prefix) using the existing choice-graph reducer with no special logic.
//
// Execution model:
//   1. Partition commands into prefix + one array per lane
//   2. Drain the prefix phase sequentially on one executor
//   3. Spawn N Tasks (one per lane) with executorPreference pointing to their LaneExecutor
//   4. Drain the run queue in schedule order until all lanes complete or a failure is detected
//
// Each Task.yield() or other suspension point in a command body produces a new continuation in the RunQueue, giving the scheduler a chance to switch lanes at that boundary.
//
// Limitation: the schedule array has one entry per non-prefix command, but the drain loop consumes one entry per dequeued job, including continuations from internal suspension points. Commands that suspend multiple times consume schedule entries meant for later commands, causing the schedule to exhaust early. Once exhausted, lane assignment falls back to deterministic round-robin (`scheduleIndex % concurrencyLevel`). Command-level lane assignment and ordering remain fully reducible; continuation-level interleavings are not encoded in the choice sequence because the number of suspension points per command is a runtime property that cannot be known before execution.
import ExhaustCore

/// Outcome of draining a single tagged command sequence through the cooperative scheduler.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
struct ConcurrentExecutionResult<Spec: AsyncStateMachineSpec> {
    /// Whether all invariants held throughout the interleaved execution.
    var passed: Bool
    /// The execution trace, populated only when `recordTrace` is true.
    var trace: [TraceStep]
    /// Whether execution stalled because no continuations arrived within the idle timeout.
    var timedOut: Bool = false
    /// The SUT state after the concurrent execution, populated only when `recordTrace` is true.
    var systemUnderTest: Spec.SystemUnderTest?
    /// The spec's failure description after the concurrent execution, populated only when `recordTrace` is true and the execution failed.
    var failureDescription: String?
    /// The concrete type name of the error behind a failure, populated on every failed execution regardless of `recordTrace`. The `time:` mode's fault inventory keys clusters on this, so it must match what the sequential executors report via `FailureSymptom.thrown(_:)` — collapsing all cooperative failures into one string would cap unrelated fault classes against each other in the reduction gate.
    var failureSymptomKind: String?
    /// What each lane observed, outer index being the zero-based lane index and each inner array in that lane's drain order.
    ///
    /// Always one entry per lane, so a lane that never ran reads as an empty array rather than a missing one. Inside a lane there is one entry per command that returned or skipped: a command that failed has no response to report, and the drain ends at the first failure. Recording is unconditional, so a probe run with `recordTrace` false carries the same responses as the final trace run.
    var laneResponses: [[ObservedResponse<Spec.Command>]] = []
    /// What the sequential prefix observed, in execution order. Kept apart from ``laneResponses`` because the linearizability search reorders lane commands and replays the prefix whole.
    var prefixResponses: [ObservedResponse<Spec.Command>] = []
    /// The lane command whose observed response no valid ordering reproduces, set by the equivalence judgement when the interleaving search names one.
    var linearizabilityWitness: ResponseWitness?
    /// Why the equivalence judgement rejected a run whose drain came back clean, for the report. Nil when the drain itself produced the failure, where the trace already shows the failing step.
    var judgementDescription: String?
}

/// Outcome of running a single command and checking its invariants inside the drain loop.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private enum CommandOutcome {
    case ok
    case skipped
    case failed(message: String, symptomKind: String)
}

/// Outcome of one call into user spec code — a command body or an invariant check — classified without touching trace or counter state.
///
/// Both calls end the same four ways, and both need their classification separated from the bookkeeping around them: the command body so the open-command counter is decremented on exactly one path, the invariant check so the straddle guard and the completion event are applied on exactly one path. Folding either into its caller's `do`/`catch` puts that bookkeeping on five exit paths, and a missed one leaves the probe permanently non-quiescent, silently disabling every later invariant check.
///
/// ``completed`` carries what the call returned so the command body's ``CommandResponse`` reaches the response recorder. An invariant check instantiates this at `Void`.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private enum SpecCallOutcome<Value> {
    case completed(Value)
    case skipped
    case checkFailed(message: String, symptomKind: String)
    case threw(message: String, symptomKind: String)
}

/// Runs one call into user spec code, classifying how it ended.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private func classifySpecCall<Value>(_ call: () async throws -> Value) async -> SpecCallOutcome<Value> {
    do {
        let value = try await call()
        return .completed(value)
    } catch is StateMachineSkip {
        return .skipped
    } catch let failure as StateMachineCheckFailure {
        return .checkFailed(
            message: failure.message ?? "check failed",
            symptomKind: String(describing: type(of: failure))
        )
    } catch {
        return .threw(message: "\(error)", symptomKind: String(describing: type(of: error)))
    }
}

/// Decides when the shared spec is safe to check invariants against.
///
/// Every lane shares one spec instance, and a `@Command` body updates the model and calls the system under test in sequence. When the system under test suspends between the two, the model has moved and the system under test has not. An invariant relating them, which is the shape the guide teaches, is false at that instant for a system under test with no defect at all.
///
/// So the check runs only when no lane is inside a command body: the gate counts open command bodies, the caller exits its own before consulting ``isQuiescent``, and a nonzero remainder means some other lane is mid-update and any model-versus-system comparison would be reading a torn state.
///
/// A deferred check is not a dropped one. Whichever command finishes last always finds the spec quiescent, so every probe is checked at least once with the model and the system under test back in agreement. That holds for a command that skips as well as one that completes: a skipping lane runs no model update of its own, but it may be the last to finish and therefore the one owing another lane's deferred check, so the skip path reaches the check too.
///
/// An `@Invariant` that suspends reopens the window from the other side: the check begins at quiescence, suspends, and another lane moves the model before it resumes. ``entries`` counts command-body entries so that case is detectable, and a verdict from a check that straddled another lane's entry is discarded rather than reported. Discarding is the safe direction; the violation, if real, persists and the next quiescent check sees it.
///
/// What is genuinely given up is a violation that exists only while another lane is suspended and heals before that lane returns. For a model-versus-system invariant that transient state is not a defect. For a structural invariant over the system under test alone, that window is now unobserved.
///
/// Copies share state: the counters live in boxes, so the one gate a probe creates observes every lane it is captured by. The boxes follow the drain loop's access discipline — touched only from the drain thread, behind the cancellation guards.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private struct QuiescenceGate {
    /// Command bodies currently open across all lanes.
    private let lanesInCommand = UnsafeSendableBox(0)
    /// Monotonic count of command bodies entered, so an invariant check that suspends can tell whether another lane moved the model while it was parked.
    private let commandEntries = UnsafeSendableBox(0)

    func enterCommand() {
        lanesInCommand.value += 1
        commandEntries.value += 1
    }

    func exitCommand() {
        lanesInCommand.value -= 1
    }

    /// Whether no lane is inside a command body, so a model-versus-system comparison reads a settled state.
    var isQuiescent: Bool {
        lanesInCommand.value == 0
    }

    /// The straddle-guard snapshot: compare before and after a check that may suspend.
    var entries: Int {
        commandEntries.value
    }
}

/// Appends one lane's trace events, or nothing when trace recording is off.
///
/// `label` is empty on the non-trace path; callers only build the (reflection-priced) command description when recording. The trace box follows the drain loop's access discipline — callers record only after a cancellation guard.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private struct LaneTraceRecorder {
    let trace: UnsafeSendableBox<[TraceEvent]>
    let isRecording: Bool
    let lane: TraceEvent.Lane
    let label: String

    func record(_ kind: TraceEvent.Kind) {
        guard isRecording else {
            return
        }
        trace.value.append(TraceEvent(kind: kind, lane: lane, label: label))
    }
}

/// Appends one lane's observed responses, stamped with monotonic call and return indices.
///
/// Cooperative execution is fully serialised by the drain loop, so wall-clock timestamps say nothing the drain order does not already say, and on a fast machine two commands can share a timestamp. One counter shared by every lane and the prefix supplies the ordering instead: one tick when a command body is entered, one when it returns. Two commands overlap exactly when their call-to-return index ranges interleave, which is the relation the linearizability checker's real-time pruning reads. The indices are exact rather than measured, so that pruning is stronger here than on the thread-based path, where a measured span only contains the true one.
///
/// Recording is unconditional, unlike trace recording: a response is data the verdict can rest on, so a probe must observe the same responses whether or not it is the run that reports.
///
/// The boxes follow the drain loop's access discipline — touched only from the drain thread, behind the cancellation guards.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private struct LaneResponseRecorder<Command> {
    let responses: UnsafeSendableBox<[ObservedResponse<Command>]>
    /// The event counter shared by every lane and the prefix. Ordering across lanes is what it exists to establish, so one counter serves them all.
    let clock: UnsafeSendableBox<UInt64>
    /// The ``ScheduleMarker`` raw value the recorded commands carried, so a linearizability witness resolves to the lane label the failure report prints. The prefix records under ``ScheduleMarker/prefix``.
    let marker: UInt8

    /// Advances the shared counter and returns this event's index.
    func tick() -> UInt64 {
        clock.value += 1
        return clock.value
    }

    func record(
        _ command: Command,
        outcome: ObservedOutcome,
        callTime: UInt64,
        returnTime: UInt64
    ) {
        responses.value.append(
            ObservedResponse(
                lane: marker,
                command: command,
                outcome: outcome,
                interval: ObservedInterval(callTime: callTime, returnTime: returnTime)
            )
        )
    }
}

/// Runs a single command, checks invariants when the spec is quiescent, and records the trace event and the observed response. Returns the outcome so the caller can handle exit flow (`break` in the prefix loop, `return` in a lane Task).
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private func runCommandRecordingTrace<Spec: AsyncStateMachineSpec>(
    _ command: Spec.Command,
    on spec: UnsafeSendableBox<Spec>,
    recorder: LaneTraceRecorder,
    responses: LaneResponseRecorder<Spec.Command>,
    gate: QuiescenceGate
) async -> CommandOutcome {
    guard Task.isCancelled == false else {
        return .skipped
    }
    recorder.record(.started)
    gate.enterCommand()
    let callTime = responses.tick()
    let bodyOutcome = await classifySpecCall { try await spec.value.run(command) }
    // A continuation resumed after abandonment runs on a GCD thread, where touching a shared box races the drain thread, so the cancellation recheck must precede the gate exit and the return tick like every other box access after a resume. The imbalance this leaves is harmless: a cancelled probe never checks invariants again and its boxes die with it.
    guard Task.isCancelled == false else {
        return .skipped
    }
    let returnTime = responses.tick()
    gate.exitCommand()

    let didSkip: Bool
    switch bodyOutcome {
        case let .completed(response):
            responses.record(
                command,
                outcome: response.returnValue.map(ObservedOutcome.returned) ?? .returnedVoid,
                callTime: callTime,
                returnTime: returnTime
            )
            didSkip = false
        case .skipped:
            recorder.record(.skipped)
            responses.record(command, outcome: .skipped, callTime: callTime, returnTime: returnTime)
            didSkip = true
        case let .checkFailed(message, symptomKind):
            recorder.record(.failed(message: message, source: .check))
            return .failed(message: message, symptomKind: symptomKind)
        case let .threw(message, symptomKind):
            recorder.record(.failed(message: message, source: .error))
            return .failed(message: message, symptomKind: symptomKind)
    }

    /// Records the completion event a non-skipping command owes and reports the step's terminal outcome. A skipped command has already recorded `.skipped` and must not also record `.completed`.
    func finish() -> CommandOutcome {
        if didSkip == false {
            recorder.record(.completed)
        }
        return didSkip ? .skipped : .ok
    }

    // A skipped command owes no check of its own, but it still runs one when it leaves the spec quiescent: it may be the last lane to finish, holding a check some other lane deferred to it.
    guard gate.isQuiescent else {
        // Another lane is mid-command. Its model update has landed and its system-under-test call has not, so any comparison between the two reads a torn state. The check this step would have made is made by whichever command finishes last.
        return finish()
    }
    let entriesAtCheckStart = gate.entries
    let checkOutcome = await classifySpecCall { try await spec.value.checkInvariants() }
    guard Task.isCancelled == false else {
        return .skipped
    }
    guard gate.entries == entriesAtCheckStart else {
        // The check suspended, and another lane opened a command body while it was parked, so its verdict rests on torn state.
        return finish()
    }
    switch checkOutcome {
        case .completed, .skipped:
            return finish()
        case let .checkFailed(message, symptomKind), let .threw(message, symptomKind):
            recorder.record(.failed(message: message, source: .invariant))
            return .failed(message: message, symptomKind: symptomKind)
    }
}

/// Applies the setup step at the head of the sequential prefix, recording it as a finished trace step.
///
/// Mirrors ``runCommandRecordingTrace(_:on:recorder:gate:)``'s guard discipline: the cancellation state is rechecked after every resume before any box is touched, so a continuation resumed after abandonment cannot race the drain thread's trace assembly.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private func runSetupRecordingTrace<Spec: AsyncStateMachineSpec>(
    _ setupStep: Spec.SetupStep,
    on spec: UnsafeSendableBox<Spec>,
    setupTrace: UnsafeSendableBox<[TraceStep]>,
    recordTrace: Bool
) async -> CommandOutcome {
    guard Task.isCancelled == false else {
        return .skipped
    }
    let setupError = await spec.value.applySetup(setupStep)
    guard Task.isCancelled == false else {
        return .skipped
    }
    if recordTrace {
        setupTrace.value.append(__ExhaustRuntime.setupTraceStep(setupStep, setupError: setupError))
    }
    guard let setupError else {
        return .ok
    }
    return .failed(message: "\(setupError)", symptomKind: String(describing: type(of: setupError)))
}

/// Transfers pending and future continuations to direct cleanup scheduling after the bounded cancellation drain cannot establish quiescence.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private func abandonTimedOutTasks(
    runQueue: RunQueue,
    executors: [LaneExecutor]
) {
    for (lane, job) in runQueue.abandon() {
        executors[Int(lane.index)].runAfterAbandonment(job)
    }
}

/// Gives cancellation-aware work a short acknowledgment window without charging the caller's full idle timeout twice.
private let cancellationDrainMilliseconds = 5

/// Drains a tagged command sequence through the cooperative scheduler with deterministic interleaving.
///
/// Execution proceeds in two phases. First, all prefix commands run sequentially on a single executor to build up whatever shared state the concurrent phase needs. Then, lane-assigned commands run concurrently via N Tasks whose continuations are interleaved by the drain loop.
///
/// The drain loop advances one continuation at a time (via `runSynchronously`), picking the lane indicated by the next schedule entry. When a command body hits an `await` (for example, `Task.yield()` inside a non-atomic read-modify-write), the task suspends and re-enqueues its continuation. The drain loop then picks another lane's continuation, producing a deterministic interleaving at that suspension point.
///
/// Every command that returns or skips is recorded against its lane as an `ObservedResponse`, stamped with monotonic call and return indices drawn from one counter shared by the prefix and every lane. Recording does not depend on `recordTrace`, because a response is evidence a verdict can rest on rather than reporting detail.
///
/// - Parameter concurrencyLevel: The number of concurrent lanes (1...8). When 1, the generator tags every command as prefix, so the entire sequence runs in the sequential prefix phase and the lane drain never executes.
/// - Parameter recordTrace: When false, trace recording is skipped for performance (used during generation and reduction where only pass/fail matters). When true, the full interleaving trace is captured for the final counterexample report.
/// - Parameter idleTimeoutMilliseconds: Maximum wall-clock time (in milliseconds) the drain loop waits with no pending jobs before declaring a timeout. Prevents infinite hangs when a continuation escapes to a foreign executor. Pass `Int.max` to disable.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
func drainSchedule<Spec: AsyncStateMachineSpec>(
    taggedCommands: [(ScheduleMarker, Spec.Command)],
    setupStep: Spec.SetupStep?,
    specInit: () -> Spec,
    concurrencyLevel: Int,
    recordTrace: Bool,
    idleTimeoutMilliseconds: Int = 1000
) -> ConcurrentExecutionResult<Spec> {
    // One pass replaces the per-lane filter passes: prefix commands, per-lane buckets, and the schedule all fall out of a single scan. The results are rebound as lets so the `@Sendable` lane tasks can capture them.
    var prefixBuffer: [Spec.Command] = []
    var laneBuffer: [[Spec.Command]] = Array(repeating: [], count: concurrencyLevel)
    var scheduleBuffer: [LaneID] = []
    for (marker, command) in taggedCommands {
        guard let laneIndex = marker.laneIndex else {
            prefixBuffer.append(command)
            continue
        }
        // Unreachable by construction: generation cannot produce a marker past the lane count and `.exact` materialization rejects one. That invariant lives two modules away, so debug builds assert an encoder that breaks it rather than degrading into a silently altered schedule; release builds drop the marker, which contributes nothing either way.
        guard Int(laneIndex) < concurrencyLevel else {
            assertionFailure("Schedule marker addresses lane \(laneIndex) but only \(concurrencyLevel) lanes exist")
            continue
        }
        scheduleBuffer.append(LaneID(index: laneIndex))
        laneBuffer[Int(laneIndex)].append(command)
    }
    let prefixCommands = prefixBuffer
    let laneCommands = laneBuffer
    let schedule = scheduleBuffer

    let runQueue = RunQueue(laneCount: concurrencyLevel)
    let executors: [LaneExecutor] = (0 ..< concurrencyLevel).map { index in
        LaneExecutor(lane: LaneID(index: UInt8(index)), runQueue: runQueue)
    }
    // Before abandonment, Task closures are nonisolated with executorPreference, so box accesses run via runSynchronously on the drain thread. After abandonment, canceled continuations can resume on GCD threads; the cancellation guards above and in both command loops prevent them from touching the trace, failure, command-index, and quiescence-gate boxes. The only cleanup writes left are prefixDone (unread after return) and RunQueue.markComplete (lock-protected).
    let spec = UnsafeSendableBox(specInit())
    // The setup step is recorded as a finished TraceStep rather than a TraceEvent: it runs at the head of the prefix phase, so it needs none of the started/suspended post-processing, and every result construction prepends it with the command steps reindexed after.
    let setupTrace = UnsafeSendableBox<[TraceStep]>([])
    let failed = UnsafeSendableBox<String?>(nil)
    // Travels beside `failed` rather than inside it: ScheduleDrain's failure flag is `String?`-typed and only checks nil-ness, so the symptom kind rides in its own box instead of widening that seam.
    let failedSymptomKind = UnsafeSendableBox<String?>(nil)
    let trace = UnsafeSendableBox<[TraceEvent]>([])
    let gate = QuiescenceGate()
    let commandIndices: [UnsafeSendableBox<Int>] = (0 ..< concurrencyLevel).map { _ in UnsafeSendableBox(0) }
    // One counter for the prefix and every lane: it exists to order events across lanes, which per-lane counters could not do.
    let responseClock = UnsafeSendableBox<UInt64>(0)
    let prefixResponses = UnsafeSendableBox<[ObservedResponse<Spec.Command>]>([])
    let laneResponses: [UnsafeSendableBox<[ObservedResponse<Spec.Command>]>] = (0 ..< concurrencyLevel).map { _ in UnsafeSendableBox([]) }

    /// Every exit path renders the same way: the setup step first, command steps reindexed after it.
    func assembleTrace() -> [TraceStep] {
        guard recordTrace else {
            return []
        }
        let commandTrace = __ExhaustRuntime.buildTrace(trace.value)
        return __ExhaustRuntime.joinTrace(setup: setupTrace.value, commands: commandTrace)
    }

    /// Reads the response boxes for a result construction. Safe on the abandonment paths for the same reason ``assembleTrace()`` is: a resumed continuation clears its cancellation guard before it can reach a box.
    func collectLaneResponses() -> [[ObservedResponse<Spec.Command>]] {
        laneResponses.map(\.value)
    }

    if setupStep != nil || prefixCommands.isEmpty == false {
        let prefixDone = UnsafeSendableBox(false)
        let prefixTask = Task(executorPreference: executors[0]) { @Sendable [spec, failed, failedSymptomKind, prefixDone, trace, setupTrace, gate, prefixResponses, responseClock] in
            // Setup is the head of the sequential prefix: it runs on every fresh spec before any command, cannot skip, and its throw fails the run with the error type as the symptom.
            if let setupStep {
                let outcome = await runSetupRecordingTrace(
                    setupStep, on: spec,
                    setupTrace: setupTrace, recordTrace: recordTrace
                )
                if case let .failed(message, symptomKind) = outcome {
                    failedSymptomKind.value = symptomKind
                    failed.value = message
                }
            }
            if failed.value == nil {
                for command in prefixCommands {
                    guard Task.isCancelled == false else { break }
                    guard failed.value == nil else { break }
                    let recorder = LaneTraceRecorder(
                        trace: trace,
                        isRecording: recordTrace,
                        lane: .prefix,
                        label: recordTrace ? "\(command)" : ""
                    )
                    let responseRecorder = LaneResponseRecorder(
                        responses: prefixResponses,
                        clock: responseClock,
                        marker: ScheduleMarker.prefix.rawValue
                    )
                    let outcome = await runCommandRecordingTrace(
                        command, on: spec, recorder: recorder, responses: responseRecorder, gate: gate
                    )
                    if case let .failed(message, symptomKind) = outcome {
                        failedSymptomKind.value = symptomKind
                        failed.value = message
                        break
                    }
                }
            }
            prefixDone.value = true
        }

        if ScheduleDrain.drainUntilDone(
            prefixDone,
            runQueue: runQueue,
            executor: executors[0],
            idleTimeoutMilliseconds: idleTimeoutMilliseconds
        ) == .timedOut {
            prefixTask.cancel()
            let cancellationOutcome = ScheduleDrain.drainUntilDone(
                prefixDone,
                runQueue: runQueue,
                executor: executors[0],
                idleTimeoutMilliseconds: cancellationDrainMilliseconds
            )
            if case .timedOut = cancellationOutcome {
                abandonTimedOutTasks(
                    runQueue: runQueue,
                    executors: executors
                )
            }
            return ConcurrentExecutionResult(
                passed: false,
                trace: assembleTrace(),
                timedOut: true,
                laneResponses: collectLaneResponses(),
                prefixResponses: prefixResponses.value
            )
        }
        if failed.value != nil {
            return ConcurrentExecutionResult(
                passed: false,
                trace: assembleTrace(),
                failureSymptomKind: failedSymptomKind.value,
                laneResponses: collectLaneResponses(),
                prefixResponses: prefixResponses.value
            )
        }
    }

    let hasAnyLaneCommands = laneCommands
        .contains { $0.isEmpty == false }
    if hasAnyLaneCommands == false {
        return ConcurrentExecutionResult(
            passed: true,
            trace: assembleTrace(),
            laneResponses: collectLaneResponses(),
            prefixResponses: prefixResponses.value
        )
    }

    var laneTasks = [Task<Void, Never>]()
    for (laneIndex, commands) in laneCommands.enumerated() {
        let lane = LaneID(index: UInt8(laneIndex))
        let executor = executors[laneIndex]
        let commandIndex = commandIndices[laneIndex]
        let laneResponseBox = laneResponses[laneIndex]
        // Responses are addressed by marker value, not lane index, so a linearizability witness resolves to the same lane label the failure report prints.
        let laneMarker = UInt8(laneIndex) + 1

        if commands.isEmpty {
            runQueue.markComplete(lane: lane)
            continue
        }

        let laneTask = Task(executorPreference: executor) { @Sendable [spec, failed, failedSymptomKind, runQueue, trace, commandIndex, gate, laneResponseBox, responseClock] in
            defer { runQueue.markComplete(lane: lane) }
            let traceLane = TraceEvent.Lane.lane(lane)
            for command in commands {
                guard Task.isCancelled == false else { return }
                guard failed.value == nil else { return }
                commandIndex.value += 1
                let label: String
                if recordTrace {
                    let name = "\(command)".split(separator: "(").first.map(String.init) ?? "\(command)"
                    label = "\(commandIndex.value)\(traceLane) \(name)"
                } else {
                    label = ""
                }
                let recorder = LaneTraceRecorder(
                    trace: trace,
                    isRecording: recordTrace,
                    lane: traceLane,
                    label: label
                )
                let responseRecorder = LaneResponseRecorder(
                    responses: laneResponseBox,
                    clock: responseClock,
                    marker: laneMarker
                )
                let outcome = await runCommandRecordingTrace(
                    command, on: spec, recorder: recorder, responses: responseRecorder, gate: gate
                )
                if case let .failed(message, symptomKind) = outcome {
                    failedSymptomKind.value = symptomKind
                    failed.value = message
                    return
                }
            }
        }
        laneTasks.append(laneTask)
    }

    // Drain the concurrent section via the core engine. Lane-switch tracking for suspended/resumed markers only exists when a trace is recorded; the nil handler on the probe path also skips the engine's per-continuation open-command bookkeeping.
    let onTraceSignal: ((ScheduleDrain.TraceSignal) -> Void)? = recordTrace
        ? { signal in
            switch signal {
                case let .suspended(lane):
                    trace.value.append(TraceEvent(kind: .suspended, lane: .lane(lane), label: ""))
                case let .resumed(lane):
                    trace.value.append(TraceEvent(kind: .resumed, lane: .lane(lane), label: ""))
            }
        }
        : nil

    if ScheduleDrain.drainConcurrentSection(
        runQueue: runQueue,
        executors: executors,
        schedule: schedule,
        concurrencyLevel: concurrencyLevel,
        idleTimeoutMilliseconds: idleTimeoutMilliseconds,
        failureFlag: failed,
        onTraceSignal: onTraceSignal
    ) == .timedOut {
        for laneTask in laneTasks {
            laneTask.cancel()
        }
        let cancellationOutcome = ScheduleDrain.drainConcurrentSection(
            runQueue: runQueue,
            executors: executors,
            schedule: schedule,
            concurrencyLevel: concurrencyLevel,
            idleTimeoutMilliseconds: cancellationDrainMilliseconds,
            failureFlag: failed,
            onTraceSignal: nil
        )
        if case .timedOut = cancellationOutcome {
            abandonTimedOutTasks(
                runQueue: runQueue,
                executors: executors
            )
        }
        return ConcurrentExecutionResult(
            passed: false,
            trace: assembleTrace(),
            timedOut: true,
            laneResponses: collectLaneResponses(),
            prefixResponses: prefixResponses.value
        )
    }

    let finalTrace = assembleTrace()
    let concurrentFailed = failed.value != nil
    return ConcurrentExecutionResult(
        passed: concurrentFailed == false,
        trace: finalTrace,
        systemUnderTest: recordTrace ? spec.value.systemUnderTest : nil,
        failureDescription: concurrentFailed && recordTrace ? spec.value.failureDescription() : nil,
        failureSymptomKind: failedSymptomKind.value,
        laneResponses: collectLaneResponses(),
        prefixResponses: prefixResponses.value
    )
}
