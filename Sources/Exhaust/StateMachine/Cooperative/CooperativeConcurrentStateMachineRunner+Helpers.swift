// Sequential oracle for concurrent spec testing.
import ExhaustCore

// MARK: - Sequential Oracle

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
extension __ExhaustRuntime {
    /// Captures the SUT and model state after a sequential (race-free) replay of the failing command sequence. Provides the "expected" baseline in failure reports so the user can see what the system should have produced without the interleaving.
    struct SequentialOracleResult<Spec: AsyncStateMachineSpec> {
        var systemUnderTest: Spec.SystemUnderTest
        var failureDescription: String?
    }

    /// Runs the command sequence sequentially on a fresh spec and returns the expected state if all invariants pass.
    ///
    /// Provides the "expected" state in the failure report: what the system should have produced without the race. If the sequential replay also fails, returns nil (the bug exists even without concurrency).
    static func sequentialOracle<Spec: AsyncStateMachineSpec>(
        commands: [Spec.Command],
        specInit: () -> Spec,
        idleTimeoutMilliseconds: Int = 1000
    ) -> SequentialOracleResult<Spec>? {
        let spec = UnsafeSendableBox(specInit())
        let runQueue = RunQueue(laneCount: 1)
        let executor = LaneExecutor(lane: LaneID(index: 0), runQueue: runQueue)
        let passed = UnsafeSendableBox(true)
        let done = UnsafeSendableBox(false)
        let oracleResult = UnsafeSendableBox<SequentialOracleResult<Spec>?>(nil)
        Task(executorPreference: executor) { @Sendable [spec, oracleResult] in
            for command in commands {
                do {
                    try await spec.value.run(command)
                    try await spec.value.checkInvariants()
                } catch is StateMachineSkip {
                    continue
                } catch {
                    passed.value = false
                    break
                }
            }
            if passed.value {
                oracleResult.value = SequentialOracleResult(
                    systemUnderTest: spec.value.systemUnderTest,
                    failureDescription: spec.value.failureDescription()
                )
            }
            done.value = true
        }

        guard ScheduleDrain.drainUntilDone(
            done,
            runQueue: runQueue,
            executor: executor,
            idleTimeoutMilliseconds: idleTimeoutMilliseconds
        ) == .completed else {
            return nil
        }

        return oracleResult.value
    }
}
