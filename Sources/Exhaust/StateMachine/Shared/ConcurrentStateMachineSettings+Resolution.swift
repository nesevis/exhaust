// Parses StateMachineSettings into a resolved concurrent configuration struct.
import ExhaustCore

/// Flattened configuration produced by parsing a `[StateMachineSettings]` array for a concurrent spec. Holds all resolved values with defaults applied, ready for the concurrent runner to consume without re-interpreting the enum cases.
struct ResolvedConcurrentConfig {
    var commandLimit: Int?
    var concurrencyLevel: Int = 2
    var budget: ExhaustBudget = .standard
    var seed: UInt64?
    var replayIteration: Int?
    var screeningReplayRow: Int?
    static let defaultIdleTimeout = 2000
    var idleTimeoutMilliseconds: Int = defaultIdleTimeout
    var suppress = SuppressFlags()
    var onReportClosure: ((ExhaustReport) -> Void)?
    var logLevel: LogLevel = .error

    var shouldRunScreening: Bool {
        replayIteration == nil
            && seed == nil
            && screeningReplayRow == nil
            && budget.screeningBudget > 0
    }

    /// Normalized idle timeout: `nil` when the configured value is non-positive or sentinel-large (``Int/max``), meaning "wait unbounded". Used by the preemptive checkers to distinguish a real timeout from an intentionally disabled one.
    var resolvedIdleTimeoutMilliseconds: Int? {
        (idleTimeoutMilliseconds > 0 && idleTimeoutMilliseconds < Int.max) ? idleTimeoutMilliseconds : nil
    }

    /// Log configuration derived from the resolved settings, shared by all concurrent entry points.
    var logConfiguration: ExhaustLog.Configuration {
        suppress.logConfiguration(minimumLevel: logLevel)
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
    }

    static func parse(_ settings: [StateMachineSettings]) -> ParseResult {
        var config = ResolvedConcurrentConfig()
        var invalidSeed: ReplaySeed?
        for setting in settings {
            switch setting {
                case let .parallelize(level):
                    config.concurrencyLevel = level.rawValue
                case let .budget(budget):
                    config.budget = budget
                case let .commandLimit(limit):
                    precondition(limit >= 1, "Command limit must be at least 1")
                    config.commandLimit = limit
                case let .replay(replaySeed):
                    if let resolved = replaySeed.resolve() {
                        switch resolved {
                            case let .sampling(resolvedSeed, iteration):
                                config.seed = resolvedSeed
                                config.replayIteration = iteration
                            case let .screening(row):
                                config.screeningReplayRow = row
                        }
                    } else {
                        invalidSeed = replaySeed
                    }
                case let .suppress(option):
                    config.applySuppress(option)
                case let .onReport(closure):
                    config.onReportClosure = config.onReportClosure.map { chained in
                        { report in
                            chained(report)
                            closure(report)
                        }
                    } ?? closure
                case let .idleTimeout(timeout):
                    config.idleTimeoutMilliseconds = Int(timeout.nanoseconds / 1_000_000)
                case let .log(level):
                    config.logLevel = level
            }
        }

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

        return ParseResult(config: config, invalidReplaySeed: invalidSeed)
    }
}
