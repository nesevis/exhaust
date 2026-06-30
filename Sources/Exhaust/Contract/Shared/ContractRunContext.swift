import ExhaustCore

/// Mutable per-run state that stays on a single GCD thread while concurrent backends probe in parallel.
///
/// Non-`Sendable` — concurrent backends internally parallelize during ``ContractBackend/probe(_:context:)`` but return synchronously before the context is mutated.
final class ContractRunContext<Spec: ContractSpecBase> {
    let config: ResolvedConcurrentConfig
    let fileID: StaticString
    let filePath: StaticString
    let line: UInt
    let column: UInt

    /// The generator used to prune and reduce the discovered candidate. The machine replaces this with the candidate's own generator before reduction so the choice sequence stays consistent with the candidate's tree.
    var sequenceGen: Generator<[(ScheduleMarker, Spec.Command)]>
    let commandGen: Generator<Spec.Command>
    let commandLimit: Int
    let identifySkips: @Sendable ([(ScheduleMarker, Spec.Command)]) -> Set<Int>
    let runStopwatch = Stopwatch()

    let invocationCounter: UnsafeSendableBox<Int>
    let lastRunTimedOutBox: UnsafeSendableBox<Bool>?
    var lastRunTimedOut: Bool {
        lastRunTimedOutBox?.value ?? false
    }

    var report = ExhaustReport()
    var deferredIssues: [String] = []
    var failureContext = __ExhaustRuntime.FailureContext()
    var probeEvidence: __ExhaustRuntime.FailureEvidence<Spec>?

    init(
        config: ResolvedConcurrentConfig,
        sequenceGen: Generator<[(ScheduleMarker, Spec.Command)]>,
        commandGen: Generator<Spec.Command>,
        commandLimit: Int,
        identifySkips: @escaping @Sendable ([(ScheduleMarker, Spec.Command)]) -> Set<Int>,
        invocationCounter: UnsafeSendableBox<Int> = UnsafeSendableBox(0),
        lastRunTimedOut: UnsafeSendableBox<Bool>? = nil,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) {
        self.config = config
        self.sequenceGen = sequenceGen
        self.commandGen = commandGen
        self.commandLimit = commandLimit
        self.identifySkips = identifySkips
        self.invocationCounter = invocationCounter
        lastRunTimedOutBox = lastRunTimedOut
        self.fileID = fileID
        self.filePath = filePath
        self.line = line
        self.column = column
    }

    var reductionDeadlineNanoseconds: UInt64 {
        config.budget.samplingBudget * 5 * 1_000_000
    }
}
