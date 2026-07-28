import ExhaustCore

/// Bundles the immutable configuration and mutable per-run state for a single spec machine run.
///
/// The struct itself is immutable — all mutation flows through the ``state`` reference. Concurrent backends internally parallelize during ``StateMachineBackend/probe(_:context:)`` but return synchronously before ``state`` is mutated.
struct StateMachineRunContext<Spec: StateMachineSpecBase> {
    let config: ResolvedConcurrentConfig
    let commandGen: Generator<Spec.Command>
    let commandLimit: Int
    let identifySkips: @Sendable (SpecCandidateValue<Spec>) -> Set<Int>
    let invocationCounter: UnsafeSendableBox<Int>
    let fileID: StaticString
    let filePath: StaticString
    let line: UInt
    let column: UInt

    let state: StateMachineRunState<Spec>

    /// Wall-clock ceiling for reducing one counterexample. A larger sampling budget raises it; nothing lowers it below ``FuzzTunables/specReductionDeadlineNanoseconds``.
    var reductionDeadlineNanoseconds: UInt64 {
        // Sampling budget says how many sequences to try. Reduction difficulty is a function of the counterexample's size and the cost of one probe, and the two are unrelated, so the budget-derived term may only raise the floor: a run configured `.custom(screening: 400, sampling: 20)` because screening finds the bug would otherwise get 100 milliseconds, which reads as a bad reducer rather than a starved one. The floor is the constant `#explore(Spec.self, time:)` already uses for identical probes, which sits above the value path's because a spec probe replays a whole command sequence against a fresh system under test.
        max(
            FuzzTunables.specReductionDeadlineNanoseconds,
            UInt64(config.budget.samplingBudget) * 5 * 1_000_000
        )
    }

    init(
        config: ResolvedConcurrentConfig,
        sequenceGen: Generator<[(ScheduleMarker, Spec.Command)]>,
        commandGen: Generator<Spec.Command>,
        commandLimit: Int,
        identifySkips: @escaping @Sendable (SpecCandidateValue<Spec>) -> Set<Int>,
        invocationCounter: UnsafeSendableBox<Int> = UnsafeSendableBox(0),
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) {
        self.config = config
        self.commandGen = commandGen
        self.commandLimit = commandLimit
        self.identifySkips = identifySkips
        self.invocationCounter = invocationCounter
        self.fileID = fileID
        self.filePath = filePath
        self.line = line
        self.column = column
        state = StateMachineRunState(sequenceGen: sequenceGen)
    }
}

/// Mutable per-run accumulators for a spec machine run.
///
/// Reference type so backends can populate diagnostic state (``failureContext``, ``probeEvidence``) through a shared reference without `inout` threading.
final class StateMachineRunState<Spec: StateMachineSpecBase> {
    /// The generator used to prune and reduce the discovered candidate. The machine replaces this with the candidate's own generator before reduction so the choice sequence stays consistent with the candidate's tree.
    var sequenceGen: Generator<[(ScheduleMarker, Spec.Command)]>
    let runStopwatch = Stopwatch()
    var report = ExhaustReport()
    var ledger = RunLedger()
    var deferredIssues: [String] = []
    var failureContext = __ExhaustRuntime.FailureContext()
    var probeEvidence: __ExhaustRuntime.FailureEvidence<Spec>?

    init(sequenceGen: Generator<[(ScheduleMarker, Spec.Command)]>) {
        self.sequenceGen = sequenceGen
    }
}
