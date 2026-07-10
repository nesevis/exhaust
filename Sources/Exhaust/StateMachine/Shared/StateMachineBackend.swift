import ExhaustCore

/// Outcome of a single backend probe, consumed by the ``SpecMachine`` to decide the next phase.
enum ProbeOutcome {
    case pass
    case fail
    case timeout
}

/// Dispatches probing, reduction, and result assembly to an execution-model-specific strategy.
///
/// The ``SpecMachine`` dispatches to the backend without knowing whether execution is sequential, cooperative, or preemptive.
protocol StateMachineBackend<Spec> {
    associatedtype Spec: StateMachineSpecBase

    /// Executes a candidate command sequence and returns whether it passed, failed, or timed out.
    ///
    /// Rich outcome data (per-lane responses, SUT snapshots, failure descriptions) is stashed internally for later use in ``buildResult(reduced:originalCommands:seed:iteration:discoveryMethod:context:)``.
    func probe(
        _ candidate: [(ScheduleMarker, Spec.Command)],
        context: StateMachineRunContext<Spec>
    ) -> ProbeOutcome

    /// Reduces a failing command sequence to a minimal counterexample.
    func reduce(
        taggedCommands: [(ScheduleMarker, Spec.Command)],
        tree: ChoiceTree,
        context: StateMachineRunContext<Spec>
    ) -> StateMachineReduction<Spec.Command>

    /// Assembles a ``StateMachineResult`` from the reduced counterexample.
    ///
    /// Populates `context.state.failureContext` with backend-specific diagnostic data (response witnesses for preemptive, oracle descriptions for cooperative).
    func buildResult(
        reduced: [(ScheduleMarker, Spec.Command)],
        originalCommands: [Spec.Command]?,
        seed: UInt64?,
        iteration: Int,
        discoveryMethod: StateMachineDiscoveryMethod,
        context: StateMachineRunContext<Spec>
    ) -> (result: StateMachineResult<Spec>, issueMessage: String)
}

extension StateMachineBackend {
    /// Probes a candidate after charging one property invocation to the run's counter.
    ///
    /// Every probe must be counted exactly once. Attribution to the screening and sampling report buckets happens by diffing the counter around each phase, so no per-invocation marking is needed. Funnel probe calls through here rather than incrementing at the call site, so the accounting invariant lives in one place.
    func countedProbe(
        _ candidate: [(ScheduleMarker, Spec.Command)],
        context: StateMachineRunContext<Spec>
    ) -> ProbeOutcome {
        context.invocationCounter.value += 1
        return probe(candidate, context: context)
    }
}

/// Carries the reduced command sequence and reduction statistics from a backend's ``StateMachineBackend/reduce(taggedCommands:tree:context:)`` call.
struct StateMachineReduction<Command> {
    let finalInput: [(ScheduleMarker, Command)]
    let stats: ReductionStats?
    let timedOut: Bool
}

extension Array {
    /// Returns a copy with all prefix-marked commands before lane commands, preserving the relative order within each group.
    ///
    /// Reduction can place prefix markers after lane markers in the array. Without normalization, the oracle replays commands in an order the concurrent execution never used, and the reported command list disagrees with the trace.
    func prefixFirstOrder<Command>() -> Self where Element == (ScheduleMarker, Command) {
        filter(\.0.isPrefix) + filter { $0.0.isPrefix == false }
    }
}
