import ExhaustCore
import Foundation

/// How long a timed-out bounded await drains for after cancelling, before calling the work escaped. Matches the cooperative runner's own cancellation drain: a task that honours cancellation returns on its next suspension point, which is immediate on this lane.
private let boundedAwaitCancellationDrainMilliseconds = 5

extension __ExhaustRuntime {
    /// Blocks the calling thread until an async closure completes and returns its result.
    ///
    /// On macOS 15+ / iOS 18+, the async work runs directly on the calling thread via a ``TaskExecutor``-based drain loop. This avoids the cooperative thread pool entirely, preventing starvation when many tests run in parallel on machines with few cores.
    ///
    /// On older platforms (no ``TaskExecutor`` API), falls back to a ``DispatchSemaphore`` that sleeps the calling thread while a cooperative-pool ``Task`` executes the work.
    ///
    /// - Important: Call from a GCD thread only. On the semaphore path, blocking a cooperative-pool thread risks deadlock. On the drain-loop path, the calling thread is occupied by ``runSynchronously`` and cannot service other work. Callers reach a GCD thread via ``dispatchToGCD(_:)`` or `DispatchQueue.global().async`.
    ///
    /// ```swift
    /// // On a GCD thread:
    /// let result = __ExhaustRuntime.blockingAwait {
    ///     try await spec.run(command)
    ///     return spec.value
    /// }
    /// ```
    package static func blockingAwait<Result>(
        _ work: @Sendable @escaping () async -> Result
    ) -> Result {
        if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
            return _blockingAwaitDrainLoop(work)
        } else {
            return _blockingAwaitSemaphore(work)
        }
    }

    /// What a bounded bridge call produced, or why it produced nothing.
    ///
    /// A bare optional cannot carry the distinction the caller needs: work that stopped when asked and work that is still running are both "no result", and only the second one goes on consuming the process and recording coverage against whatever runs next.
    enum BoundedAwaitOutcome<Success> {
        /// The work finished within the bound.
        case completed(Success)

        /// The idle timeout fired and the cancellation drain then completed, so nothing from this call is still running. Any value the work produced under cancellation is discarded: it did not finish on its own terms.
        case quiesced

        /// The idle timeout fired and cancellation did not drain either, so the work was abandoned while still running.
        case escaped

        /// The outcome as the disposition the concurrent runners speak in.
        var disposition: ExecutionDisposition {
            switch self {
                case .completed:
                    .completed
                case .quiesced:
                    .timedOutQuiesced
                case .escaped:
                    .timedOutEscaped
            }
        }

        /// The value when the work finished within the bound, and nil for either timeout. For callers whose degraded path is the same either way.
        var value: Success? {
            guard case let .completed(value) = self else {
                return nil
            }
            return value
        }
    }

    /// Like ``blockingAwait(_:)`` but gives up if the work makes no progress within `idleTimeoutMilliseconds`, cancelling it and reporting whether the cancellation took.
    ///
    /// Use when the awaited work may suspend onto a foreign executor (the main actor, a custom-executor actor, the global pool, `Task.sleep`, or I/O bridged through a continuation that resumes elsewhere). Such a continuation never returns to this single drain lane, so the unbounded ``blockingAwait(_:)`` would park the calling thread indefinitely. The bound mirrors the cooperative scheduler's idle timeout: the drain-loop path measures time since the last drained job (so legitimately long-but-active work does not trip it); the semaphore fallback measures total wall-clock.
    static func blockingAwait<Result>(
        idleTimeoutMilliseconds: Int,
        _ work: @Sendable @escaping () async -> Result
    ) -> BoundedAwaitOutcome<Result> {
        if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
            return _blockingAwaitDrainLoopBounded(idleTimeoutMilliseconds: idleTimeoutMilliseconds, work)
        }
        return _blockingAwaitSemaphoreBounded(timeoutMilliseconds: idleTimeoutMilliseconds, work)
    }

    /// The bounded drain loop: retains its task so a timeout can cancel it, then drains again briefly to see whether the cancellation took.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    private static func _blockingAwaitDrainLoopBounded<Result>(
        idleTimeoutMilliseconds: Int,
        _ work: @Sendable @escaping () async -> Result
    ) -> BoundedAwaitOutcome<Result> {
        let lane = LaneID(index: 0)
        let runQueue = RunQueue(laneCount: 1)
        let executor = LaneExecutor(lane: lane, runQueue: runQueue)
        let box = UnsafeSendableBox<Result?>(nil)
        let done = UnsafeSendableBox(false)

        let task = Task(executorPreference: executor) { @Sendable in
            box.value = await work()
            done.value = true
        }

        if ScheduleDrain.drainUntilDone(
            done,
            runQueue: runQueue,
            executor: executor,
            idleTimeoutMilliseconds: idleTimeoutMilliseconds
        ) == .completed, let value = box.value {
            return .completed(value)
        }

        // The continuation suspended onto an executor that will not feed this lane. Ask it to stop, then drain briefly: whether it comes back is the difference between work that ended and work that is still running.
        task.cancel()
        let cancellationOutcome = ScheduleDrain.drainUntilDone(
            done,
            runQueue: runQueue,
            executor: executor,
            idleTimeoutMilliseconds: boundedAwaitCancellationDrainMilliseconds
        )
        if cancellationOutcome == .completed {
            return .quiesced
        }

        // The caller no longer drains this queue after returning `.escaped`. Abandonment schedules queued and future jobs on the fallback executor, allowing the task to finish and release its captures.
        for (_, job) in runQueue.abandon() {
            executor.runAfterAbandonment(job)
        }
        return .escaped
    }

    /// Runs the task's continuations on the calling thread via a single-lane ``RunQueue`` and ``LaneExecutor``, avoiding the cooperative pool entirely. The unbounded form: it waits for the work and cannot bail, so the bounded caller uses ``_blockingAwaitDrainLoopBounded(idleTimeoutMilliseconds:_:)`` instead, which can cancel.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    private static func _blockingAwaitDrainLoop<Result>(
        _ work: @Sendable @escaping () async -> Result
    ) -> Result {
        let lane = LaneID(index: 0)
        let runQueue = RunQueue(laneCount: 1)
        let executor = LaneExecutor(lane: lane, runQueue: runQueue)
        let box = UnsafeSendableBox<Result?>(nil)
        let done = UnsafeSendableBox(false)

        Task(executorPreference: executor) { @Sendable in
            box.value = await work()
            done.value = true
        }

        // No idle bound, so the drain returns only once `done` is set, and the box holds the result by then.
        _ = ScheduleDrain.drainUntilDone(
            done,
            runQueue: runQueue,
            executor: executor,
            idleTimeoutMilliseconds: nil
        )
        return box.value!
    }

    /// The bounded semaphore fallback: retains its task so a timeout can cancel it, then waits briefly to see whether the cancellation took.
    ///
    /// The cooperative pool gives this path no lane to drain, so the second wait is the only way to tell work that stopped from work that is still running. Without it a timed-out task keeps mutating the system under test after the caller moves on, and later attempts record its coverage as their own.
    private static func _blockingAwaitSemaphoreBounded<Result>(
        timeoutMilliseconds: Int,
        _ work: @Sendable @escaping () async -> Result
    ) -> BoundedAwaitOutcome<Result> {
        let box = UnsafeSendableBox<Result?>(nil)
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task { @Sendable in
            box.value = await work()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + .milliseconds(timeoutMilliseconds)) == .success,
           let value = box.value
        {
            return .completed(value)
        }

        // Ask the work to stop, then wait the window the drain-loop path gives cancellation: a task that honours it returns at its next suspension point.
        task.cancel()
        guard semaphore.wait(timeout: .now() + .milliseconds(boundedAwaitCancellationDrainMilliseconds)) == .success
        else {
            return .escaped
        }
        return .quiesced
    }

    /// Creates a cooperative-pool task and sleeps the calling thread until it completes. The unbounded form; ``_blockingAwaitSemaphoreBounded(timeoutMilliseconds:_:)`` is the one that can give up.
    package static func _blockingAwaitSemaphore<Result>(
        _ work: @Sendable @escaping () async -> Result
    ) -> Result {
        let box = UnsafeSendableBox<Result?>(nil)
        let semaphore = DispatchSemaphore(value: 0)
        Task { @Sendable in
            box.value = await work()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }

    /// Dispatches a synchronous closure onto a GCD thread and returns the result asynchronously.
    ///
    /// Moves work off the cooperative thread pool so that synchronous blocking (drain loops, semaphore waits) inside `work` cannot starve the pool. GCD's global queue is far larger than the fixed cooperative pool, so it does not starve the way the cooperative pool does — but it is not unbounded (a top-level concurrent queue caps at 64 threads), so callers that fan out lanes reserve through ``LaneGate`` via `dispatchToGCD(reserving:)` to keep aggregate demand under that wall.
    ///
    /// The `nonisolated(unsafe)` annotations bridge non-Sendable generic values across the GCD boundary. Safety relies on the closure and its result being created and consumed by the same logical unit of work — no concurrent access is possible because the continuation resumes only after `work` returns.
    ///
    /// Every hop binds a ``DeferredIssueSink`` around `work` and replays it after the continuation resumes: issue recording resolves the current test from task-locals the GCD worker does not carry, so a report recorded inside `work` would misroute as a runtime warning. Deferring at the hop makes reporting placement inside dispatched bodies a non-decision for entry points.
    static func dispatchToGCD<Result>(
        _ work: @escaping () -> Result
    ) async -> Result {
        let issueSink = DeferredIssueSink()
        nonisolated(unsafe) let unsafeWork = work
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
            DispatchQueue.global().async {
                let result = DeferredIssueSink.$current.withValue(issueSink) {
                    unsafeWork()
                }
                nonisolated(unsafe) let unsafeResult = result
                continuation.resume(returning: unsafeResult)
            }
        }
        issueSink.replay()
        return result
    }

    /// Acquires `lanes` from the process-global ``LaneGate``, performs the GCD hop, and releases on the way out.
    ///
    /// The reservation is held for the whole run: the entire discovery pipeline (regression replay, screening, sampling, reduction) runs synchronously inside `work`, so it never re-enters the gate. Excess runs suspend at the gate as parked continuations holding no thread, bounding aggregate GCD lane demand to ``LaneGate/limit`` regardless of how many test functions Swift Testing runs at once. Use ``LaneReservation`` for the lane count.
    static func dispatchToGCD<Result>(
        reserving lanes: Int,
        _ work: @escaping () -> Result
    ) async -> Result {
        await LaneGate.shared.acquire(lanes)
        // Release inside the GCD closure, on the GCD thread, rather than in a `defer` after the `await` (which resumes on the cooperative pool). Keeping release off the cooperative pool means it never has to wait on a cooperative thread that admitted runs may be occupying through their `blockingAwait` continuations.
        return await dispatchToGCD {
            defer { LaneGate.shared.release(lanes) }
            return work()
        }
    }
}
