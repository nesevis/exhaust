/// Resolved configuration for a contract test run, parsed from ``ContractSettings`` and source location.
struct ContractContext {
    var commandLimit: Int?
    var budget: ExhaustBudget = .standard
    var replay: ReplaySeed.Resolved?
    var hasInvalidReplaySeed: Bool = false
    var suppressIssueReporting: Bool = false
    var suppressLogs: Bool = false
    var collectOpenPBTStats: Bool = false
    var includeDiff: Bool = false
    var onReportClosure: ((ExhaustReport) -> Void)?
    var logLevel: LogLevel = .error
    let fileID: StaticString
    let filePath: StaticString
    let line: UInt
    let column: UInt

    private var generatedSeed: UInt64?

    var coverageBudget: UInt64 {
        budget.coverageBudget
    }

    var samplingBudget: UInt64 {
        budget.samplingBudget
    }

    var seed: UInt64? {
        samplingReplaySeed ?? generatedSeed
    }

    mutating func ensureSeed() {
        guard samplingReplaySeed == nil, generatedSeed == nil else { return }
        generatedSeed = Xoshiro256().seed
    }

    var isSamplingReplay: Bool {
        guard case .sampling = replay else { return false }
        return true
    }

    var isCoverageReplay: Bool {
        guard case .coverage = replay else { return false }
        return true
    }

    var samplingReplaySeed: UInt64? {
        guard case let .sampling(seed, _) = replay else { return nil }
        return seed
    }

    var samplingReplayIteration: Int? {
        guard case let .sampling(_, iteration) = replay else { return nil }
        return iteration
    }

    var coverageReplayRow: Int? {
        guard case let .coverage(row) = replay else { return nil }
        return row
    }

    func propertySettings(
        samplingBudget: UInt64,
        coverageBudget: UInt64,
        onReport: ((ExhaustReport) -> Void)? = nil
    ) -> [PropertySettings] {
        var settings: [PropertySettings] = [
            .budget(.custom(coverage: coverageBudget, sampling: samplingBudget)),
        ]
        if let iteration = samplingReplayIteration, let seed {
            settings.append(.replay(.encoded(ReplaySeed.Resolved.sampling(seed: seed, iteration: iteration).encoded)))
        } else if let seed {
            settings.append(.replay(.numeric(seed)))
        }
        settings.append(.suppress(.issueReporting))
        if suppressLogs {
            settings.append(.suppress(.logs))
        }
        if collectOpenPBTStats {
            settings.append(.collectOpenPBTStats)
        }
        if let onReport {
            settings.append(.onReport(onReport))
        }
        settings.append(.log(logLevel))
        return settings
    }

    static func logConfiguration(from settings: [ContractSettings]) -> ExhaustLog.Configuration {
        var suppressLogs = false
        var logLevel: LogLevel = .error
        for setting in settings {
            switch setting {
                case let .suppress(option):
                    if case .logs = option { suppressLogs = true }
                    if case .all = option { suppressLogs = true }
                case let .log(level):
                    logLevel = level
                default:
                    break
            }
        }
        return ExhaustLog.Configuration(isEnabled: suppressLogs == false, minimumLevel: logLevel, format: .keyValue)
    }

    var encodedReplaySeed: String? {
        replay?.encoded ?? seed.map(ReplaySeed.encodeRawSeed)
    }

    init(
        settings: [ContractSettings],
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt
    ) {
        self.fileID = fileID
        self.filePath = filePath
        self.line = line
        self.column = column

        for setting in settings {
            switch setting {
                case let .commandLimit(limit):
                    commandLimit = max(Int(limit), 1)
                case let .budget(value):
                    budget = value
                case let .replay(replaySeed):
                    if let resolved = replaySeed.resolve() {
                        replay = resolved
                    } else {
                        hasInvalidReplaySeed = true
                    }
                case let .suppress(option):
                    switch option {
                        case .issueReporting:
                            suppressIssueReporting = true
                        case .logs:
                            suppressLogs = true
                        case .all:
                            suppressIssueReporting = true
                            suppressLogs = true
                    }
                case .collectOpenPBTStats:
                    collectOpenPBTStats = true
                case .includeDiff:
                    includeDiff = true
                case let .onReport(closure):
                    let existing = onReportClosure
                    onReportClosure = { report in
                        existing?(report)
                        closure(report)
                    }
                case let .log(level):
                    logLevel = level
                case .concurrent:
                    ExhaustLog.notice(
                        category: .propertyTest,
                        event: "setting_ignored",
                        ".concurrent is only used with .tasks or .threads contracts"
                    )
                case .idleTimeoutMs:
                    ExhaustLog.notice(
                        category: .propertyTest,
                        event: "setting_ignored",
                        ".idleTimeoutMs is only used with .tasks or .threads contracts"
                    )
            }
        }

        #if canImport(Testing)
            if let traitConfig = ExhaustTraitConfiguration.current {
                let hasInlineBudget = settings.contains { if case .budget = $0 { true } else { false } }
                if hasInlineBudget == false, let traitBudget = traitConfig.budget {
                    budget = traitBudget
                }
            }
        #endif
    }
}
