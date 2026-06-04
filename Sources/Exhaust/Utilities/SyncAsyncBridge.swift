import Foundation

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
    static func blockingAwait<Result>(
        _ work: @Sendable @escaping () async -> Result
    ) -> Result {
        if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
            // A nil idle timeout never bails, so the force-unwrap is safe: the loop only returns once the work completes.
            return _blockingAwaitDrainLoop(idleTimeoutMilliseconds: nil, work)!
        } else {
            return _blockingAwaitSemaphore(timeoutMilliseconds: nil, work)!
        }
    }

    /// Like ``blockingAwait(_:)`` but bails with `nil` if the work makes no progress within `idleTimeoutMilliseconds`.
    ///
    /// Use when the awaited work may suspend onto a foreign executor (the main actor, a custom-executor actor, the global pool, `Task.sleep`, or I/O bridged through a continuation that resumes elsewhere). Such a continuation never returns to this single drain lane, so the unbounded ``blockingAwait(_:)`` would spin a CPU core forever. The bound mirrors the cooperative scheduler's idle timeout: the drain-loop path measures time since the last drained job (so legitimately long-but-active work does not trip it); the semaphore fallback measures total wall-clock.
    static func blockingAwait<Result>(
        idleTimeoutMilliseconds: Int,
        _ work: @Sendable @escaping () async -> Result
    ) -> Result? {
        if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
            return _blockingAwaitDrainLoop(idleTimeoutMilliseconds: idleTimeoutMilliseconds, work)
        } else {
            return _blockingAwaitSemaphore(timeoutMilliseconds: idleTimeoutMilliseconds, work)
        }
    }

    /// Runs the task's continuations on the calling thread via a single-lane ``RunQueue`` and ``LaneExecutor``, avoiding the cooperative pool entirely. Returns `nil` when `idleTimeoutMilliseconds` is non-nil and no job is drained within that window while the work is still incomplete.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    private static func _blockingAwaitDrainLoop<Result>(
        idleTimeoutMilliseconds: Int?,
        _ work: @Sendable @escaping () async -> Result
    ) -> Result? {
        let lane = LaneID(index: 0)
        let runQueue = RunQueue(laneCount: 1)
        let executor = LaneExecutor(lane: lane, runQueue: runQueue)
        let box = UnsafeSendableBox<Result?>(nil)
        let done = UnsafeSendableBox(false)

        Task(executorPreference: executor) { @Sendable in
            box.value = await work()
            done.value = true
        }

        // Reset the idle timer whenever a job is drained, so only a genuine stall — the work suspended onto another executor — trips the bound.
        var idleStopwatch = Stopwatch()
        while done.value == false {
            if let (_, job) = runQueue.dequeue(preferring: lane) {
                job.runSynchronously(on: executor.asUnownedTaskExecutor())
                idleStopwatch = Stopwatch()
            } else if let idleTimeoutMilliseconds {
                // No job to run and the work has not completed — the continuation has suspended onto another executor and will not return to this lane. Bail rather than spin forever. The orphaned Task retains `box`/`done`, so its later resumption only writes to boxes we no longer read.
                if runQueue.waitForJob(
                    idleTimeoutMilliseconds: idleTimeoutMilliseconds,
                    elapsedMilliseconds: idleStopwatch.elapsedMilliseconds
                ) == false {
                    return nil
                }
            } else {
                runQueue.waitForJob()
            }
        }
        return box.value
    }

    /// Creates a cooperative-pool task and sleeps the calling thread until it completes. Returns `nil` when `timeoutMilliseconds` is non-nil and the work does not complete within it.
    package static func _blockingAwaitSemaphore<Result>(
        timeoutMilliseconds: Int?,
        _ work: @Sendable @escaping () async -> Result
    ) -> Result? {
        let box = UnsafeSendableBox<Result?>(nil)
        let semaphore = DispatchSemaphore(value: 0)
        Task { @Sendable in
            box.value = await work()
            semaphore.signal()
        }
        if let timeoutMilliseconds {
            if semaphore.wait(timeout: .now() + .milliseconds(timeoutMilliseconds)) == .timedOut {
                return nil
            }
        } else {
            semaphore.wait()
        }
        return box.value
    }

    /// Dispatches a synchronous closure onto a GCD thread and returns the result asynchronously.
    ///
    /// Moves work off the cooperative thread pool so that synchronous blocking (drain loops, semaphore waits) inside `work` cannot starve the pool. GCD grows its thread pool dynamically, so concurrent callers cannot exhaust it the way they can exhaust cooperative threads.
    ///
    /// The `nonisolated(unsafe)` annotations bridge non-Sendable generic values across the GCD boundary. Safety relies on the closure and its result being created and consumed by the same logical unit of work — no concurrent access is possible because the continuation resumes only after `work` returns.
    static func dispatchToGCD<Result>(
        _ work: @escaping () -> Result
    ) async -> Result {
        nonisolated(unsafe) let unsafeWork = work
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
            DispatchQueue.global().async {
                let result = unsafeWork()
                nonisolated(unsafe) let unsafeResult = result
                continuation.resume(returning: unsafeResult)
            }
        }
    }
}
