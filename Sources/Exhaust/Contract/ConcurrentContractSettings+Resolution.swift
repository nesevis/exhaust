// Parses ConcurrentContractSettings into a resolved configuration struct.
import ExhaustCore

/// Flattened configuration produced by parsing a `[ConcurrentContractSettings]` array. Holds all resolved values with defaults applied, ready for the concurrent runner to consume without re-interpreting the enum cases.
struct ResolvedConcurrentConfig {
    var commandLimit: Int?
    var concurrencyLevel: Int = 2
    var budget: ExhaustBudget = .standard
    var seed: UInt64?
    var replayIteration: Int?
    var coverageReplayRow: Int?
    var idleTimeout: Int = 1000
    var suppressIssueReporting: Bool = false
    var suppressLogs: Bool = false
    var collectOpenPBTStats: Bool = false
    var onReportClosure: ((ExhaustReport) -> Void)?
    var logLevel: LogLevel = .error
    let logFormat: LogFormat = .keyValue

    var shouldRunCoverage: Bool {
        replayIteration == nil
            && (seed == nil || coverageReplayRow != nil)
            && budget.coverageBudget > 0
    }

    enum ParseResult {
        case success(ResolvedConcurrentConfig)
        case invalidReplaySeed(ReplaySeed)
        case invalidConcurrencyLevel(Int)
    }

    static func parse(_ settings: [ConcurrentContractSettings]) -> ParseResult {
        var config = ResolvedConcurrentConfig()
        for setting in settings {
            switch setting {
                case let .concurrent(level):
                    config.concurrencyLevel = level
                case let .budget(b):
                    config.budget = b
                case let .commandLimit(limit):
                    config.commandLimit = limit
                case let .replay(replaySeed):
                    guard let resolved = replaySeed.resolve() else {
                        return .invalidReplaySeed(replaySeed)
                    }
                    switch resolved {
                        case let .sampling(resolvedSeed, iteration):
                            config.seed = resolvedSeed
                            config.replayIteration = iteration
                        case let .coverage(row):
                            config.coverageReplayRow = row
                    }
                case let .suppress(option):
                    switch option {
                        case .issueReporting:
                            config.suppressIssueReporting = true
                        case .logs:
                            config.suppressLogs = true
                        case .all:
                            config.suppressIssueReporting = true
                            config.suppressLogs = true
                    }
                case .collectOpenPBTStats:
                    config.collectOpenPBTStats = true
                case let .onReport(closure):
                    if let existing = config.onReportClosure {
                        let chained = existing
                        config.onReportClosure = { report in
                            chained(report)
                            closure(report)
                        }
                    } else {
                        config.onReportClosure = closure
                    }
                case let .idleTimeoutMs(ms):
                    config.idleTimeout = ms
                case let .log(level):
                    config.logLevel = level
            }
        }
        guard 1 ... 8 ~= config.concurrencyLevel else {
            return .invalidConcurrencyLevel(config.concurrencyLevel)
        }
        return .success(config)
    }
}
