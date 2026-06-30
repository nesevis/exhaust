import ExhaustCore

/// Routes a single probe outcome from the backend to the ``ContractMachine``'s scheduler.
enum ProbeOutcome {
    case pass
    case fail
    case timeout
}

/// Dispatches probing, reduction, and result assembly to an execution-model-specific strategy.
///
/// The ``ContractMachine`` dispatches to the backend without knowing whether execution is sequential, cooperative, or preemptive.
protocol ContractBackend<Spec> {
    associatedtype Spec: ContractSpecBase

    /// Executes a candidate command sequence and returns whether it passed, failed, or timed out.
    ///
    /// Rich outcome data (per-lane responses, SUT snapshots, failure descriptions) is stashed internally for later use in ``buildResult(reduced:originalCommands:seed:iteration:discoveryMethod:context:)``.
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
    /// Populates `context.failureContext` with backend-specific diagnostic data (response witnesses for preemptive, oracle descriptions for cooperative).
    func buildResult(
        reduced: [(ScheduleMarker, Spec.Command)],
        originalCommands: [Spec.Command]?,
        seed: UInt64?,
        iteration: Int,
        discoveryMethod: ContractDiscoveryMethod,
        context: ContractRunContext<Spec>
    ) -> (result: ContractResult<Spec>, issueMessage: String)
}

/// Carries the reduced command sequence and reduction statistics from a backend's ``ContractBackend/reduce(taggedCommands:tree:context:)`` call.
struct ContractReduction<Command> {
    let finalInput: [(ScheduleMarker, Command)]
    let stats: ReductionStats?
    let timedOut: Bool
}
