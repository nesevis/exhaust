// Parses ConcurrentContractSettings into a resolved configuration struct.
import ExhaustCore

/// Flattened configuration produced by parsing a `[ConcurrentContractSettings]` array. Holds all resolved values with defaults applied, ready for the concurrent runner to consume without re-interpreting the enum cases.
struct ResolvedConcurrentConfig {
    var commandLimit: Int?
    var concurrencyLevel: Int = 2
    var budget: ExhaustBudget = .thorough
    var seed: UInt64?
    var idleTimeout: Int = 1000
    var suppressIssueReporting: Bool = false
    var suppressLogs: Bool = false
    var useRandomOnly: Bool = false
    var collectOpenPBTStats: Bool = false
    var onReportClosure: ((ExhaustReport) -> Void)?
    var logLevel: LogLevel = .error
    var logFormat: LogFormat = .keyValue

    enum ParseResult {
        case success(ResolvedConcurrentConfig)
        case invalidReplaySeed(ReplaySeed)
    }

    static func parse(_ settings: [ConcurrentContractSettings]) -> ParseResult {
        var config = ResolvedConcurrentConfig()
        for setting in settings {
            switch setting {
            case let .concurrency(level):
                config.concurrencyLevel = level
            case let .budget(b):
                config.budget = b
            case let .commandLimit(limit):
                config.commandLimit = limit
            case let .replay(replaySeed):
                guard let resolved = replaySeed.resolve() else {
                    return .invalidReplaySeed(replaySeed)
                }
                config.seed = resolved
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
            case .randomOnly:
                config.useRandomOnly = true
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
            case let .logging(level, format):
                config.logLevel = level
                config.logFormat = format
            }
        }
        return .success(config)
    }
}
