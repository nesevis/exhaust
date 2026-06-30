import ExhaustCore

/// Accumulates mutable state for a single contract test run.
///
/// Non-`Sendable` — the machine and context live on a single GCD thread. Concurrent backends internally parallelize during ``ContractBackend/probe(_:context:)`` but return synchronously before the context is mutated.
final class ContractRunContext<Spec: ContractSpecBase> {
    let config: ResolvedConcurrentConfig
    let fileID: StaticString
    let filePath: StaticString
    let line: UInt
    let column: UInt

    let sequenceGen: Generator<[(ScheduleMarker, Spec.Command)]>
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

    lazy var reductionConfig = Interpreters.ReducerConfiguration(
        maxStalls: 2,
        wallClockDeadlineNanoseconds: config.budget.samplingBudget * 5 * 1_000_000,
        tuning: SchedulerTuning(relaxMaterializationBudget: 0)
    )
}
