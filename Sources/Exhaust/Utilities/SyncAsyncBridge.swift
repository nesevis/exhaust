import ExhaustCore
import Foundation

extension __ExhaustRuntime {
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
    ///
    /// `work` receives the nanoseconds this run spent parked at the gate. That span is queueing behind other runs, not work this run performed, so a caller holding a wall-clock budget stamped before the call must discount it. Without that discount a busy `--parallel` suite can retire the whole budget before the first probe. Callers with no wall-clock budget ignore the parameter.
    static func dispatchToGCD<Result>(
        reserving lanes: Int,
        _ work: @escaping (UInt64) -> Result
    ) async -> Result {
        let gateStopwatch = Stopwatch()
        await LaneGate.shared.acquire(lanes)
        let gateWaitNanoseconds = gateStopwatch.elapsedNanoseconds
        // Release inside the GCD closure, on the GCD thread, rather than in a `defer` after the `await` (which resumes on the cooperative pool). Keeping release off the cooperative pool means it never has to wait on a cooperative thread that admitted runs may be occupying through their `blockingAwait` continuations.
        return await dispatchToGCD {
            defer { LaneGate.shared.release(lanes) }
            return work(gateWaitNanoseconds)
        }
    }
}
