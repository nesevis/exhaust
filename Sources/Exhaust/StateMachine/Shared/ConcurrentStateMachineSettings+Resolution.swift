// Parses StateMachineSettings into a resolved concurrent configuration struct.
import ExhaustCore

/// Flattened configuration produced by parsing a `[StateMachineSettings]` array for a concurrent spec. Holds all resolved values with defaults applied, ready for the concurrent runner to consume without re-interpreting the enum cases.
extension ResolvedConcurrentConfig {
    /// Creates a configuration at the ``ExhaustBudget/standard`` budget that reports warnings through the test framework.
    init() {
        self.init(
            screeningBudget: ExhaustBudget.standard.screeningBudget,
            samplingBudget: ExhaustBudget.standard.samplingBudget
        )
        reportWarning = { message, fileID, filePath, line, column in
            Exhaust.reportWarning(message, fileID: fileID, filePath: filePath, line: line, column: column)
        }
    }

    /// Both phase budgets as an ``ExhaustBudget``. Reading it returns the equivalent `.custom` budget.
    var budget: ExhaustBudget {
        get {
            .custom(screening: screeningBudget, sampling: samplingBudget)
        }
        set {
            screeningBudget = newValue.screeningBudget
            samplingBudget = newValue.samplingBudget
        }
    }

    /// The suppression flags, read from and written to the three suppression values.
    var suppress: SuppressFlags {
        get {
            var flags = SuppressFlags()
            flags.issueReporting = suppressIssueReporting
            flags.logs = suppressLogs
            flags.attachments = suppressAttachments
            return flags
        }
        set {
            suppressIssueReporting = newValue.issueReporting
            suppressLogs = newValue.logs
            suppressAttachments = newValue.attachments
        }
    }

    /// Delivers each finished run's report to `onReport`, built from the run's record.
    mutating func setOnReport(_ onReport: ((ExhaustReport) -> Void)?) {
        onRunRecord = onReport.map { onReport in
            { record in
                onReport(ExhaustReport(stateMachineRun: record))
            }
        }
    }

    /// Extracts log configuration from raw settings.
    static func logConfiguration(from settings: [StateMachineSettings]) -> ExhaustLog.Configuration {
        parse(settings).config.logConfiguration
    }

    mutating func applySuppress(_ option: SuppressOption) {
        suppress.apply(option)
    }

    struct ParseResult {
        var config: ResolvedConcurrentConfig
        var invalidReplaySeed: ReplaySeed?
        /// The `.commandLimit` value the caller requested when it exceeded ``ResolvedConcurrentConfig/maxCommandLimit``, or nil when no clamping occurred.
        var clampedCommandLimit: Int?

        /// Warns that an explicit `.commandLimit` was clamped. Call at the entry point, where the caller's source location is available; does nothing when no clamping occurred.
        func reportCommandLimitClampWarning(
            fileID: StaticString,
            filePath: StaticString,
            line: UInt,
            column: UInt
        ) {
            guard let requested = clampedCommandLimit else { return }
            Exhaust.reportWarning(
                ".commandLimit(\(requested)) exceeds the supported maximum of \(ResolvedConcurrentConfig.maxCommandLimit) and was clamped. Covering-array construction cost grows superlinearly with sequence length, so longer sequences spend their budget building coverage rows instead of executing commands.",
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
        }
    }

    static func parse(_ settings: [StateMachineSettings]) -> ParseResult {
        let runStart = MonotonicClock.nanoseconds()
        var config = ResolvedConcurrentConfig()
        var invalidSeed: ReplaySeed?
        var clampedCommandLimit: Int?
        var onReport: ((ExhaustReport) -> Void)?
        for setting in settings {
            switch setting {
                case let .parallelize(level):
                    config.concurrencyLevel = level.rawValue
                case let .budget(budget):
                    config.budget = budget
                case let .deadline(duration):
                    let (deadline, overflow) = runStart.addingReportingOverflow(duration.nanoseconds)
                    config.deadlineNanoseconds = overflow ? .max : deadline
                case let .commandLimit(limit):
                    precondition(limit >= 1, "Command limit must be at least 1")
                    if limit > maxCommandLimit {
                        clampedCommandLimit = limit
                        config.commandLimit = maxCommandLimit
                    } else {
                        config.commandLimit = limit
                    }
                case let .replay(replaySeed):
                    if let resolved = replaySeed.resolve() {
                        switch resolved {
                            case let .sampling(resolvedSeed, iteration):
                                config.seed = resolvedSeed
                                config.replayIteration = iteration
                                config.coveringSeed = resolvedSeed
                            case let .specScreening(resolvedSeed, row, tierLength):
                                config.screeningReplay = (tierLength: tierLength, row: row)
                                config.coveringSeed = resolvedSeed
                            case .valueScreening:
                                // A tierless seed addresses a value test's single array and cannot pick a tier here.
                                invalidSeed = replaySeed
                        }
                    } else {
                        invalidSeed = replaySeed
                    }
                case let .suppress(option):
                    config.applySuppress(option)
                case let .onReport(closure):
                    onReport = onReport.map { chained in
                        { report in
                            chained(report)
                            closure(report)
                        }
                    } ?? closure
                case let .idleTimeout(timeout):
                    // The drain loop counts whole milliseconds. A nonzero span below 1 ms rounds up rather than truncating to 0, which would silently disable the timeout the caller asked for.
                    config.idleTimeoutMilliseconds = timeout == .zero
                        ? 0
                        : max(1, Int(timeout.nanoseconds / 1_000_000))
                case let .log(level):
                    config.logLevel = level
            }
        }
        config.setOnReport(onReport)

        #if canImport(Testing)
            // Adopt a suite-level `.budget` trait when no inline `.budget` was passed, matching the sequential resolver. Without this, all three concurrent runners silently ignore a budget set via a Swift Testing trait.
            if let traitConfig = ExhaustTraitConfiguration.current {
                let hasInlineBudget = settings.contains { if case .budget = $0 { true } else { false } }
                if hasInlineBudget == false, let traitBudget = traitConfig.budget {
                    config.budget = traitBudget
                }
            }
        #endif
        config.budget.preconditionValid()

        return ParseResult(config: config, invalidReplaySeed: invalidSeed, clampedCommandLimit: clampedCommandLimit)
    }
}

// MARK: - Report

extension ExhaustReport {
    /// Builds the report for a finished state machine run.
    init(stateMachineRun record: StateMachineRunRecord) {
        self.init()
        screeningMilliseconds = record.screeningMilliseconds
        reductionMilliseconds = record.reductionMilliseconds
        if let reductionStats = record.reductionStats {
            applyReductionStats(reductionStats)
        }
        if record.reductionWasCapped {
            reductionWasCapped = true
        }
        applyLedger(record.ledger)
        hasExceededDeadline = record.hasExceededDeadline
        seed = record.seed
        totalMilliseconds = record.totalMilliseconds
    }
}
