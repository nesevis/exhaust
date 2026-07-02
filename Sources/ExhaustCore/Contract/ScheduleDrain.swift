/// Concrete drain loops for the cooperative scheduler.
///
/// The loops operate exclusively on non-generic data — ``RunQueue``, `UnownedJob`, ``LaneID``, and flag boxes — so they compile as concrete code under this module's whole-module optimization. The Spec-generic callers in the Exhaust module (the cooperative contract runner, the sequential oracle, and the blocking-await bridge) spawn their lane Tasks first, then hand the per-continuation loop to one of these entry points. The boundary crossing is once per probe.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
package enum ScheduleDrain {
    /// How a drain loop ended: the work completed, or no continuation arrived within the idle timeout.
    package enum Outcome {
        case completed
        case timedOut
    }

    /// A lane-switch event the schedule-following loop reports while a trace is being recorded.
    ///
    /// `suspended` fires when the loop leaves a lane that still has an open command; `resumed` fires when it returns to one. The caller translates these into trace events — the loop itself never touches trace storage, so the non-trace path passes `nil` and skips the per-lane open-command bookkeeping entirely.
    package enum TraceSignal {
        case suspended(LaneID)
        case resumed(LaneID)
    }

    /// Drains jobs for a single-lane workload until `done` flips, preferring the given executor's lane.
    ///
    /// Serves the sequential prefix phase, the sequential oracle replay, and the blocking-await bridge — all "run one logical task to completion on the calling thread" shapes. Pass `nil` for `idleTimeoutMilliseconds` to wait indefinitely (the blocking-await bridge's unbounded mode); otherwise the loop bails with ``Outcome/timedOut`` when no job is drained within the window, which happens when a continuation suspends onto a foreign executor and never returns to this lane.
    package static func drainUntilDone(
        _ done: UnsafeSendableBox<Bool>,
        runQueue: RunQueue,
        executor: LaneExecutor,
        idleTimeoutMilliseconds: Int?
    ) -> Outcome {
        // Reset the idle timer whenever a job is drained, so only a genuine stall — the work suspended onto another executor — trips the bound.
        var idleStopwatch = Stopwatch()
        while done.value == false {
            if let (_, job) = runQueue.dequeue(preferring: executor.lane) {
                job.runSynchronously(on: executor.asUnownedTaskExecutor())
                idleStopwatch = Stopwatch()
            } else if let idleTimeoutMilliseconds {
                if runQueue.waitForJob(
                    idleTimeoutMilliseconds: idleTimeoutMilliseconds,
                    elapsedMilliseconds: idleStopwatch.elapsedMilliseconds
                ) == false {
                    return .timedOut
                }
            } else {
                runQueue.waitForJob()
            }
        }
        return .completed
    }

    /// Drains the concurrent section of a schedule until every lane completes, a failure is flagged, or the idle timeout expires.
    ///
    /// One iteration drains one continuation: the next schedule entry names the preferred lane (falling back to round-robin once the schedule is exhausted, and to any pending lane when the preferred one has nothing), the job runs via `runSynchronously`, and the failure flag is checked so a failed lane stops the drain without waiting for the others. Each iteration takes the queue lock exactly once on the non-trace path, via ``RunQueue/dequeueOrStatus(preferring:)``.
    ///
    /// - Parameters:
    ///   - failureFlag: Set by a lane task when a command fails. A non-nil value ends the drain; the caller reads the message afterwards.
    ///   - onTraceSignal: Receives lane-switch events for trace recording, or `nil` to skip all per-lane open-command bookkeeping (one extra lock acquisition per continuation) on the hot path.
    package static func drainConcurrentSection(
        runQueue: RunQueue,
        executors: [LaneExecutor],
        schedule: [LaneID],
        concurrencyLevel: Int,
        idleTimeoutMilliseconds: Int,
        failureFlag: UnsafeSendableBox<String?>,
        onTraceSignal: ((TraceSignal) -> Void)?
    ) -> Outcome {
        var lastDrainedLane: LaneID?
        var laneHasOpenCommand: [LaneID: Bool] = onTraceSignal == nil
            ? [:]
            : Dictionary(uniqueKeysWithValues: (0 ..< concurrencyLevel).map { (LaneID(index: UInt8($0)), false) })
        var scheduleIndex = 0
        var idleStopwatch = Stopwatch()

        while true {
            let preferred = scheduleIndex < schedule.count
                ? schedule[scheduleIndex]
                : LaneID(index: UInt8(scheduleIndex % concurrencyLevel))
            switch runQueue.dequeueOrStatus(preferring: preferred) {
                case .finished:
                    return .completed
                case .empty:
                    if runQueue.waitForJob(
                        idleTimeoutMilliseconds: idleTimeoutMilliseconds,
                        elapsedMilliseconds: idleStopwatch.elapsedMilliseconds
                    ) == false {
                        return .timedOut
                    }
                case let .job(lane, job):
                    scheduleIndex += 1
                    if let onTraceSignal {
                        let switchedLanes = lastDrainedLane != nil && lastDrainedLane != lane
                        if switchedLanes, let previous = lastDrainedLane, laneHasOpenCommand[previous] == true {
                            onTraceSignal(.suspended(previous))
                        }
                        if switchedLanes, laneHasOpenCommand[lane] == true {
                            onTraceSignal(.resumed(lane))
                        }
                    }
                    job.runSynchronously(on: executors[Int(lane.index)].asUnownedTaskExecutor())
                    if onTraceSignal != nil {
                        laneHasOpenCommand[lane] = runQueue.hasPendingJob(for: lane)
                    }
                    lastDrainedLane = lane
                    idleStopwatch = Stopwatch()
                    if failureFlag.value != nil {
                        return .completed
                    }
            }
        }
    }
}
