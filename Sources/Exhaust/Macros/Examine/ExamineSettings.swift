import IssueReporting

/// Controls how ``#examine`` reports validation failures for a specific check.
///
/// Each severity level determines both whether a failure appears in test output and whether it causes the test to fail. Use `.error` (the default) when validation failures should block the test, `.warning` when you want visibility without failure, and `.silent` when you only need the data in the returned ``ExamineReport``.
///
/// ```swift
/// #examine(personGen, .reflection(.warning))
/// #examine(personGen, .severity(.silent))
/// ```
public enum ExamineSeverity: Sendable {
    /// Reports the failure via `reportIssue` at error severity, causing the test to fail.
    case error
    /// Reports the failure via `reportIssue` at warning severity. The issue appears in test output but does not cause the test to fail.
    case warning
    /// Does not report the failure. The check still runs and its results appear in the returned ``ExamineReport``.
    case silent

    /// Maps to ``IssueReporting/IssueSeverity``, or `nil` for `.silent`.
    package var issueSeverity: IssueSeverity? {
        switch self {
            case .error: .error
            case .warning: .warning
            case .silent: nil
        }
    }
}

/// Controls test behavior for ``#examine`` validation runs, passed as variadic arguments.
///
/// ```swift
/// #examine(personGen, .reflection(.warning), .budget(500))
/// #examine(personGen, .severity(.silent), .reflection(.error))
/// ```
public enum ExamineSettings: Sendable {
    /// Sets the default severity for all checks that do not have an explicit per-check override.
    ///
    /// When combined with per-check settings, the per-check setting takes precedence:
    /// ```swift
    /// #examine(gen, .severity(.silent), .reflection(.warning))
    /// ```
    case severity(ExamineSeverity)

    /// Controls the severity of reflection round-trip failures.
    ///
    /// The reflection check generates a value, reflects it back through the generator to obtain a choice tree, replays that tree, and compares the result. A mismatch indicates a broken `backward` mapping or a non-injective generator that reflection cannot invert.
    case reflection(ExamineSeverity)

    /// Controls the severity of filter validity rate failures.
    ///
    /// The filter health check monitors what fraction of generated candidates survive each filter predicate. A validity rate below 5% triggers a failure, indicating that the generator is spending most of its budget on rejection.
    case filterHealth(ExamineSeverity)

    /// Sets the number of values to generate and validate. Defaults to 200 when omitted.
    case budget(Int)

    /// Sets a fixed seed for deterministic validation runs.
    ///
    /// Accepts a raw `UInt64` or a Crockford Base32 string:
    /// ```swift
    /// .replay(42)
    /// .replay("3RT5GH8KM2")
    /// ```
    case replay(ReplaySeed)

    /// Suppresses log output, issue reporting, or both.
    ///
    /// Use `.suppress(.issueReporting)` when the test asserts on the returned ``ExamineReport`` rather than relying on the framework to record the failure. Use `.suppress(.logs)` to silence console output. Use `.suppress(.all)` for a completely silent run.
    /// ```swift
    /// #examine(gen, .suppress(.logs))
    /// #examine(gen, .suppress(.all))
    /// ```
    case suppress(SuppressOption)
}

// MARK: - Resolved Configuration

/// Stores the resolved per-check severity configuration derived from ``ExamineSettings``.
///
/// Per-check severity overrides take precedence over the global ``ExamineSettings/severity(_:)`` setting. Both take precedence over the built-in default of ``ExamineSeverity/error``.
package struct ExamineReportingConfiguration {
    /// Severity for reflection round-trip failures.
    var reflectionSeverity: ExamineSeverity
    /// Severity for filter validity rate failures.
    var filterHealthSeverity: ExamineSeverity
    /// Number of values to generate and validate.
    var samples: Int
    /// Replay seed for deterministic runs, or `nil` for random.
    var replaySeed: ReplaySeed?
    /// Whether to suppress log output.
    var suppressLogs: Bool
    /// Whether to suppress issue reporting.
    var suppressIssueReporting: Bool

    /// Builds a configuration by resolving an array of ``ExamineSettings``.
    ///
    /// Per-check settings override ``ExamineSettings/severity(_:)``, which overrides the built-in default of ``ExamineSeverity/error``. When the same setting appears multiple times, the last one wins.
    ///
    /// - Parameter settings: The settings to resolve.
    init(from settings: [ExamineSettings]) {
        var globalSeverity: ExamineSeverity?
        var reflectionOverride: ExamineSeverity?
        var filterHealthOverride: ExamineSeverity?
        var samples = 200
        var replaySeed: ReplaySeed?
        var suppressLogs = false
        var suppressIssueReporting = false

        for setting in settings {
            switch setting {
                case let .severity(value):
                    globalSeverity = value
                case let .reflection(value):
                    reflectionOverride = value
                case let .filterHealth(value):
                    filterHealthOverride = value
                case let .budget(count):
                    precondition(count >= 0, "Budget must be non-negative")
                    samples = count
                case let .replay(seed):
                    replaySeed = seed
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
            }
        }

        let base = globalSeverity ?? .error
        reflectionSeverity = reflectionOverride ?? base
        filterHealthSeverity = filterHealthOverride ?? base
        self.samples = samples
        self.replaySeed = replaySeed
        self.suppressLogs = suppressLogs
        self.suppressIssueReporting = suppressIssueReporting
    }
}
