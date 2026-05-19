// MARK: - Cooperative Drain Loop for Concurrent Contract Execution
//
// Executes a tagged command sequence through a cooperative scheduler that deterministically controls interleaving at every `await` boundary. The input is a flat [(ScheduleMarker, Command)] array that encodes both the lane partition AND the interleaving order:
//
//   - ScheduleMarker(rawValue: 0) → prefix: runs sequentially before the concurrent phase (state setup)
//   - ScheduleMarker(rawValue: 1...N) → assigns to lane a...n; array position defines drain order
//
// The array order of non-prefix markers becomes the schedule: when the drain loop needs to pick which lane to advance, it consults the next marker in sequence. This encoding means reduction can simultaneously shrink commands (array deletion) and reduce concurrency (marker minimization toward 0/prefix) using the existing choice-graph reducer with no special logic.
//
// Execution model:
//   1. Partition commands into prefix + one array per lane
//   2. Drain the prefix phase sequentially on one executor
//   3. Spawn N Tasks (one per lane) with executorPreference pointing to their LaneExecutor
//   4. Drain the run queue in schedule order until all lanes complete or a failure is detected
//
// Each Task.yield() or other suspension point in a command body produces a new continuation in the RunQueue, giving the scheduler a chance to switch lanes at that boundary.
import ExhaustCore

/// Assigns a command to a scheduling lane in a concurrent contract test.
///
/// During generation, the marker generator produces values in 0...N (where N is the concurrency level). The reducer's value-minimization pass drives markers toward 0 (prefix), naturally discovering which commands must remain concurrent to reproduce the failure. Commands whose markers reach prefix move to the sequential phase, proving they are not part of the minimal concurrent counterexample.
///
/// Value 0 is the sequential prefix. Values 1 through N map to lanes "a" through the Nth letter.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
public struct ScheduleMarker: RawRepresentable, Sendable, Equatable, Hashable, CustomStringConvertible {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The sequential prefix marker. Commands with this marker run before any interleaving begins.
    public static let prefix = ScheduleMarker(rawValue: 0)

    /// Whether this marker assigns to the sequential prefix rather than a concurrent lane.
    public var isPrefix: Bool { rawValue == 0 }

    /// The zero-based lane index, or nil if this is the prefix marker.
    var laneIndex: UInt8? { rawValue > 0 ? rawValue - 1 : nil }

    public var description: String {
        if rawValue == 0 { return "prefix" }
        return String(UnicodeScalar(UInt8(ascii: "a") + rawValue - 1))
    }
}

/// Outcome of draining a single tagged command sequence through the cooperative scheduler.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
struct ConcurrentExecutionResult {
    /// Whether all invariants held throughout the interleaved execution.
    var passed: Bool
    /// The execution trace, populated only when `recordTrace` is true.
    var trace: [TraceStep]
    /// Whether execution stalled because no continuations arrived within the idle timeout.
    var timedOut: Bool = false
}

/// Drains a tagged command sequence through the cooperative scheduler with deterministic interleaving.
///
/// Execution proceeds in two phases. First, all prefix commands run sequentially on a single executor — this builds up whatever shared state the concurrent phase needs. Then, lane-assigned commands run concurrently via N Tasks whose continuations are interleaved by the drain loop.
///
/// The drain loop advances one continuation at a time (via `runSynchronously`), picking the lane indicated by the next schedule entry. When a command body hits an `await` (for example, `Task.yield()` inside a non-atomic read-modify-write), the task suspends and re-enqueues its continuation. The drain loop then picks another lane's continuation, producing a deterministic interleaving at that suspension point.
///
/// - Parameter concurrencyLevel: The number of concurrent lanes (1...8). When 1, all non-prefix commands run on a single lane with no interleaving (fast path).
/// - Parameter recordTrace: When false, trace recording is skipped for performance (used during generation and reduction where only pass/fail matters). When true, the full interleaving trace is captured for the final counterexample report.
/// - Parameter idleTimeoutMilliseconds: Maximum wall-clock time (in milliseconds) the drain loop waits with no pending jobs before declaring a timeout. Prevents infinite hangs when a continuation escapes to a foreign executor. Pass `Int.max` to disable.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
func drainSchedule<Spec: AsyncContractSpec>(
    taggedCommands: [(ScheduleMarker, Spec.Command)],
    specInit: () -> Spec,
    concurrencyLevel: Int,
    recordTrace: Bool,
    idleTimeoutMilliseconds: Int = 1000
) -> ConcurrentExecutionResult {
    let idleTimeout: Duration = .milliseconds(idleTimeoutMilliseconds)

    let prefixCommands = taggedCommands.filter { $0.0.isPrefix }.map(\.1)
    let laneCommands: [[Spec.Command]] = (0 ..< concurrencyLevel).map { laneIndex in
        let marker = ScheduleMarker(rawValue: UInt8(laneIndex + 1))
        return taggedCommands.filter { $0.0 == marker }.map(\.1)
    }
    let schedule: [LaneID] = taggedCommands.compactMap { marker, _ in
        guard let laneIndex = marker.laneIndex else { return nil }
        return LaneID(index: laneIndex)
    }

    let runQueue = RunQueue(laneCount: concurrencyLevel)
    let executors: [LaneExecutor] = (0 ..< concurrencyLevel).map { index in
        LaneExecutor(lane: LaneID(index: UInt8(index)), runQueue: runQueue)
    }
    // Shared mutable state accessed from Task closures and the drain loop. Thread safety relies on the cooperative single-threaded execution model: all Task closures execute via runSynchronously on the drain loop thread, and LaneExecutor.enqueue (the only re-entry point) is called synchronously within runSynchronously's suspension machinery. No concurrent access is possible as long as all continuations flow through LaneExecutor. If a continuation arrives from a foreign executor (custom-executor actor, Task.sleep), RunQueue itself would race first — the SendableBox invariant is the same as RunQueue's.
    let spec = SendableBox(specInit())
    let failed = SendableBox<String?>(nil)
    let trace = SendableBox<[TraceEvent]>([])
    let commandIndices: [SendableBox<Int>] = (0 ..< concurrencyLevel).map { _ in SendableBox(0) }

    // Phase 1: Prefix — run sequentially, drain fully before concurrent phase.
    if prefixCommands.isEmpty == false {
        let prefixDone = SendableBox(false)
        Task(executorPreference: executors[0]) { @Sendable [spec, failed, prefixDone, trace] in
            for command in prefixCommands {
                guard failed.value == nil else { break }
                let label = "\(command)"
                if recordTrace { trace.value.append(TraceEvent(kind: .started, lane: "prefix", label: label)) }
                do {
                    try await spec.value.run(command)
                    try await spec.value.checkInvariants()
                    if recordTrace { trace.value.append(TraceEvent(kind: .completed, lane: "prefix", label: label)) }
                } catch is ContractSkip {
                    if recordTrace { trace.value.append(TraceEvent(kind: .completed, lane: "prefix", label: label)) }
                } catch let failure as ContractCheckFailure {
                    let message = failure.message ?? "check failed"
                    if recordTrace { trace.value.append(TraceEvent(kind: .failed(message: message), lane: "prefix", label: label)) }
                    failed.value = message
                    break
                } catch {
                    if recordTrace { trace.value.append(TraceEvent(kind: .failed(message: "\(error)"), lane: "prefix", label: label)) }
                    failed.value = "\(error)"
                    break
                }
            }
            prefixDone.value = true
        }

        var lastActivity = ContinuousClock.now
        while prefixDone.value == false {
            guard let (_, job) = runQueue.dequeue(preferring: LaneID(index: 0)) else {
                let elapsed = ContinuousClock.now - lastActivity
                if elapsed > idleTimeout {
                    return ConcurrentExecutionResult(passed: false, trace: recordTrace ? buildTrace(trace.value) : [], timedOut: true)
                }
                continue
            }
            job.runSynchronously(on: executors[0].asUnownedTaskExecutor())
            lastActivity = ContinuousClock.now
        }
        if failed.value != nil {
            return ConcurrentExecutionResult(passed: false, trace: recordTrace ? buildTrace(trace.value) : [])
        }
    }

    // Phase 2: Concurrent — spawn one task per lane with interleaving.
    let hasAnyLaneCommands = laneCommands.contains { $0.isEmpty == false }
    if hasAnyLaneCommands == false {
        return ConcurrentExecutionResult(passed: true, trace: recordTrace ? buildTrace(trace.value) : [])
    }

    for (laneIndex, commands) in laneCommands.enumerated() {
        let lane = LaneID(index: UInt8(laneIndex))
        let executor = executors[laneIndex]
        let commandIndex = commandIndices[laneIndex]

        if commands.isEmpty {
            runQueue.markComplete(lane: lane)
            continue
        }

        Task(executorPreference: executor) { @Sendable [spec, failed, runQueue, trace, commandIndex] in
            let laneLabel = lane.label
            for command in commands {
                guard failed.value == nil else { return }
                commandIndex.value += 1
                let name = "\(command)".split(separator: "(").first.map(String.init) ?? "\(command)"
                let label = "\(commandIndex.value)\(laneLabel.uppercased()) \(name)"
                if recordTrace { trace.value.append(TraceEvent(kind: .started, lane: laneLabel, label: label)) }
                do {
                    try await spec.value.run(command)
                    try await spec.value.checkInvariants()
                    if recordTrace { trace.value.append(TraceEvent(kind: .completed, lane: laneLabel, label: label)) }
                } catch is ContractSkip {
                    if recordTrace { trace.value.append(TraceEvent(kind: .completed, lane: laneLabel, label: label)) }
                } catch let failure as ContractCheckFailure {
                    let message = failure.message ?? "check failed"
                    if recordTrace { trace.value.append(TraceEvent(kind: .failed(message: message), lane: laneLabel, label: label)) }
                    failed.value = message
                    return
                } catch {
                    if recordTrace { trace.value.append(TraceEvent(kind: .failed(message: "\(error)"), lane: laneLabel, label: label)) }
                    failed.value = "\(error)"
                    return
                }
            }
            runQueue.markComplete(lane: lane)
        }
    }

    // Drain concurrent section with lane-switch tracking for suspended/resumed markers.
    var lastDrainedLane: LaneID?
    var laneHasOpenCommand: [LaneID: Bool] = Dictionary(
        uniqueKeysWithValues: (0 ..< concurrencyLevel).map { (LaneID(index: UInt8($0)), false) }
    )
    var scheduleIndex = 0

    var lastActivity = ContinuousClock.now

    while runQueue.isFinished == false {
        if runQueue.hasPendingJobs == false {
            let elapsed = ContinuousClock.now - lastActivity
            if elapsed > idleTimeout {
                let finalTrace: [TraceStep] = recordTrace ? buildTrace(trace.value) : []
                return ConcurrentExecutionResult(passed: false, trace: finalTrace, timedOut: true)
            }
            continue
        }
        let preferred = scheduleIndex < schedule.count
            ? schedule[scheduleIndex]
            : LaneID(index: UInt8(scheduleIndex % concurrencyLevel))
        scheduleIndex += 1
        guard let (lane, job) = runQueue.dequeue(preferring: preferred) else { break }
        let executor = executors[Int(lane.index)]

        if recordTrace {
            let switchedLanes = lastDrainedLane != nil && lastDrainedLane != lane
            if switchedLanes, let prev = lastDrainedLane, laneHasOpenCommand[prev] == true {
                trace.value.append(TraceEvent(kind: .suspended, lane: prev.label, label: ""))
            }
            if switchedLanes && laneHasOpenCommand[lane] == true {
                trace.value.append(TraceEvent(kind: .resumed, lane: lane.label, label: ""))
            }
        }

        job.runSynchronously(on: executor.asUnownedTaskExecutor())
        laneHasOpenCommand[lane] = runQueue.hasPendingJob(for: lane)
        lastDrainedLane = lane
        lastActivity = ContinuousClock.now

        if failed.value != nil {
            break
        }
    }

    let finalTrace: [TraceStep] = recordTrace ? buildTrace(trace.value) : []
    return ConcurrentExecutionResult(passed: failed.value == nil, trace: finalTrace)
}
