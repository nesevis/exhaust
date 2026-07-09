import ExhaustCore

/// Defines the per-probe operations that differ between the synchronous and async preemptive runners.
///
/// Conformers are captured into the `@Sendable` property closure handed to the SCA coverage and reduction passes, so they must be `Sendable`. Both current conformers store only an `Int?` timeout, so the requirement is trivially satisfied.
protocol PreemptiveBackend<Spec>: Sendable {
    associatedtype Spec: StateMachineSpecBase

    /// Builds the skip-identifier closure used to prune precondition-failing commands before reduction. The two backends construct it differently (a static identifier versus a `specInit`-seeded async bridge).
    func makeIdentifySkips() -> @Sendable ([(ScheduleMarker, Spec.Command)]) -> Set<Int>

    /// Runs one tagged command sequence concurrently using a pre-computed lane partition.
    ///
    /// The partition holds index buckets into `taggedCommands`; both must describe the same sequence.
    func execute(_ taggedCommands: [(ScheduleMarker, Spec.Command)], partition: LanePartition) -> Preemptive.Outcome<Spec>

    /// Runs a command sequence sequentially on a fresh spec for the smoke phase, capturing the trace, whether it failed, whether it timed out, and the resulting oracle state for the report.
    ///
    /// `timedOut` distinguishes a stalling command (which must route to the timeout path and skip reduction) from a genuine smoke failure. The synchronous backend runs unbounded and never times out.
    func runSmoke(_ commands: [Spec.Command]) -> (trace: [TraceStep], failed: Bool, timedOut: Bool, systemUnderTest: Spec.SystemUnderTest, failureDescription: String?)

    /// Checks whether a concurrent execution's observed responses are consistent with some valid sequential ordering.
    ///
    /// Called after lane-collapse reduction on oracle-flagged failures. If any valid interleaving produces matching responses and passes the oracle, the execution is linearizable and the failure was a false positive.
    ///
    /// - Parameters:
    ///   - taggedCommands: The full tagged command sequence (prefix + concurrent).
    ///   - laneResponses: The per-lane observed responses from `Outcome.laneResponses`.
    ///   - concurrentSpec: The concurrent spec instance after execution, kept alive for oracle calls.
    /// - Returns: The linearizability verdict with closest-ordering information on failure.
    func checkLinearizability(
        taggedCommands: [(ScheduleMarker, Spec.Command)],
        laneResponses: [[ObservedResponse<Spec.Command>]],
        concurrentSpec: Spec
    ) -> LinearizabilityResult

    /// Replays the reduced commands sequentially on a fresh spec and returns its failure description, the expected race-free state for the report. Returns nil when the replay itself fails, because the partial state would mislead debugging.
    func sequentialReplayDescription(of reduced: [(ScheduleMarker, Spec.Command)]) -> String?
}
