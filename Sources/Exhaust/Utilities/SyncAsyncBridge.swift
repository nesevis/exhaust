import Foundation

extension __ExhaustRuntime {
    /// Blocks the calling thread until an async closure completes and returns its result.
    ///
    /// Internally creates an unstructured ``Task`` and sleeps the calling thread on a
    /// ``DispatchSemaphore`` until the task signals completion. The semaphore provides
    /// the happens-before guarantee that makes the unsynchronized result hand-off safe.
    ///
    /// - Important: Call from a GCD thread only. Blocking a cooperative-pool thread
    ///   while the ``Task`` needs pool threads to schedule its continuations will deadlock.
    ///   Callers reach a GCD thread via ``dispatchToGCD(_:)`` or
    ///   `DispatchQueue.global().async`.
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
    /// Moves work off the cooperative thread pool so that synchronous blocking
    /// (drain loops, semaphore waits) inside `work` cannot starve the pool. GCD
    /// grows its thread pool dynamically, so concurrent callers cannot exhaust it
    /// the way they can exhaust cooperative threads.
    ///
    /// The `nonisolated(unsafe)` annotations bridge non-Sendable generic values
    /// across the GCD boundary. Safety relies on the closure and its result being
    /// created and consumed by the same logical unit of work — no concurrent
    /// access is possible because the continuation resumes only after `work`
    /// returns.
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
