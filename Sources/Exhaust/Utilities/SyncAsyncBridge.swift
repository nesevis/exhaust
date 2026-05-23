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
            return _blockingAwaitDrainLoop(work)
        } else {
            return _blockingAwaitSemaphore(work)
        }
    }

    /// Runs the task's continuations on the calling thread via a single-lane ``RunQueue`` and ``LaneExecutor``, avoiding the cooperative pool entirely.
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

        while done.value == false {
            if let (_, job) = runQueue.dequeue(preferring: lane) {
                job.runSynchronously(on: executor.asUnownedTaskExecutor())
            }
        }
        return box.value!
    }

    /// Creates a cooperative-pool task and sleeps the calling thread until it completes.
    private static func _blockingAwaitSemaphore<Result>(
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
