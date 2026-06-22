import ExhaustCore

/// The per-probe operations that differ between the synchronous and async preemptive runners.
///
/// Everything else (phase ordering, smoke, SCA coverage, sampling, reduction, and failure assembly) is shared in ``__ExhaustRuntime/runPreemptivePipeline(backend:config:)``. The synchronous backend runs commands directly on GCD threads; the async backend bridges each probe through a drain loop.
///
/// Conformers are captured into the `@Sendable` property closure handed to the SCA coverage and reduction passes, so they must be `Sendable`. Both checkers store only an `Int?` timeout, so this is unconditional.
protocol PreemptiveBackend<Spec>: Sendable {
    associatedtype Spec: ContractSpecBase

    /// Builds the skip-identifier closure used to prune precondition-failing commands before reduction. The two backends construct it differently (a static identifier versus a `specInit`-seeded async bridge).
    func makeIdentifySkips() -> @Sendable ([(ScheduleMarker, Spec.Command)]) -> Set<Int>

    /// Runs one tagged command sequence concurrently and reports whether invariants and the oracle held.
    func execute(_ taggedCommands: [(ScheduleMarker, Spec.Command)]) -> Preemptive.Outcome<Spec>

    /// Runs a command sequence sequentially on a fresh spec for the smoke phase, capturing the trace, whether it failed, and the resulting oracle state for the report.
    func runSmoke(_ commands: [Spec.Command]) -> (trace: [TraceStep], failed: Bool, systemUnderTest: Spec.SystemUnderTest, failureDescription: String?)

    /// Checks whether a concurrent execution's observed responses are consistent with some valid sequential ordering.
    ///
    /// Called after lane-collapse reduction on oracle-flagged failures. If any valid interleaving produces matching responses and passes the oracle, the execution is linearizable and the failure was a false positive.
    ///
    /// - Parameters:
    ///   - prefix: The sequential prefix commands.
    ///   - laneResponses: The per-lane observed responses from `Outcome.laneResponses`.
    ///   - concurrentSpec: The concurrent spec instance after execution, kept alive for oracle calls.
    /// - Returns: The linearizability verdict with closest-ordering information on failure.
    func checkLinearizability(
        taggedCommands: [(ScheduleMarker, Spec.Command)],
        laneResponses: [[ObservedResponse<Spec.Command>]],
        concurrentSpec: Spec,
        observationHashes: [[UInt64]]?,
        prefixCache: inout LinearizabilityPrefixCache?
    ) -> LinearizabilityResult

    /// Replays the reduced commands sequentially on a fresh spec to capture the expected (race-free) oracle state for a failure result.
    func buildResult(
        reduced: [(ScheduleMarker, Spec.Command)],
        seed: UInt64?,
        replaySeed: String?,
        discoveryMethod: ContractDiscoveryMethod
    ) -> (result: ContractResult<Spec>, failureDescription: String?)
}
