import ExhaustCore

enum ProbeOutcome {
    case pass
    case fail
    case timeout
}

/// Execution-model-specific strategy for probing, reducing, and assembling contract results.
///
/// The ``ContractMachine`` dispatches to the backend without knowing whether execution is
/// sequential, cooperative, or preemptive.
protocol ContractBackend<Spec> {
    associatedtype Spec: ContractSpecBase

    /// Executes a candidate command sequence and returns whether it passed, failed, or timed out.
    ///
    /// Rich outcome data (per-lane responses, SUT snapshots, failure descriptions) is stashed
    /// internally for later use in ``buildResult(reduced:originalCommands:seed:iteration:discoveryMethod:context:)``.
    func probe(
        _ candidate: [(ScheduleMarker, Spec.Command)],
        context: ContractRunContext<Spec>
    ) -> ProbeOutcome

    /// Reduces a failing command sequence to a minimal counterexample.
    func reduce(
        taggedCommands: [(ScheduleMarker, Spec.Command)],
        tree: ChoiceTree,
        context: ContractRunContext<Spec>
    ) -> ContractReduction<Spec.Command>

    /// Assembles a ``ContractResult`` from the reduced counterexample.
    ///
    /// Populates `context.failureContext` with backend-specific diagnostic data
    /// (response witnesses for preemptive, oracle descriptions for cooperative).
    func buildResult(
        reduced: [(ScheduleMarker, Spec.Command)],
        originalCommands: [Spec.Command]?,
        seed: UInt64?,
        iteration: Int,
        discoveryMethod: ContractDiscoveryMethod,
        context: ContractRunContext<Spec>
    ) -> (result: ContractResult<Spec>, issueMessage: String)
}

/// Result of reducing a contract counterexample.
struct ContractReduction<Command> {
    let finalInput: [(ScheduleMarker, Command)]
    let stats: ReductionStats?
    let timedOut: Bool
}
