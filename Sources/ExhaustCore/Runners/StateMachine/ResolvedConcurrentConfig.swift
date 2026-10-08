// The resolved configuration a state machine run executes under.

// MARK: - Resolved Configuration

/// A state machine run's configuration after settings parsing: plain values the engine reads, plus the two hooks through which it reaches the test framework.
///
/// Parsing the public settings, applying a suite-level budget trait, and turning reports into the public report type all happen in the Exhaust module, which builds this value. The engine never sees a settings or report type.
package struct ResolvedConcurrentConfig {
    /// The largest `.commandLimit` a run accepts. Covering-array construction cost grows superlinearly with sequence length: an explicit `.commandLimit(20000)` on a passing sequential spec exceeded a 2-minute limit on a 5+5 budget where the raw command executions cost milliseconds. Parse clamps larger values here and records the request for the entry point to warn about, mirroring how `.tasks` caps its own estimate at 40.
    package static let maxCommandLimit = 200

    package var commandLimit: Int?
    package var concurrencyLevel: Int = 2
    package var screeningBudget: Int
    package var samplingBudget: Int
    /// Absolute monotonic deadline, preserved when the config is copied for regression replays.
    package var deadlineNanoseconds: UInt64?

    package var hasExceededDeadline: Bool {
        deadlineNanoseconds.map { MonotonicClock.nanoseconds() >= $0 } ?? false
    }

    package var seed: UInt64?
    package var replayIteration: Int?
    /// The screening row to replay, addressed tier-locally: the sequence length identifying the tier and the 0-based row within its covering array.
    package var screeningReplay: (tierLength: Int, row: Int)?
    /// Seeds the SCA covering array. A screening replay carries it in the seed string, a sampling replay reuses its PRNG seed so a bare seed pins the whole pipeline, and a fresh run draws one, so successive runs screen different regions of the command space instead of the same rows.
    package var coveringSeed: UInt64 = Xoshiro256().seed

    /// The default idle timeout for concurrent drains, in milliseconds.
    package static let defaultIdleTimeout = 2000
    package var idleTimeoutMilliseconds: Int = defaultIdleTimeout

    package var suppressIssueReporting = false
    package var suppressLogs = false
    package var suppressAttachments = false
    package var logLevel: LogLevel = .error

    /// Receives the run's record when it finishes, for building the caller's report. Nil when nobody asked for one.
    package var onRunRecord: ((StateMachineRunRecord) -> Void)?

    /// Reports a warning at a source location, or nil to drop warnings.
    package var reportWarning: ((String, StaticString, StaticString, UInt, UInt) -> Void)?

    /// Creates a configuration with the given phase budgets and every other value at its default.
    package init(screeningBudget: Int, samplingBudget: Int) {
        self.screeningBudget = screeningBudget
        self.samplingBudget = samplingBudget
    }

    /// Whether the run performs the full SCA screening sweep. Targeted replays (a sampling iteration or a screening row) skip it: they must reproduce one failure, and a fresh sweep could surface an unrelated one first. A bare seed is not a targeted replay — it promises the whole pipeline deterministically under that seed, so it keeps the sweep, pinned through ``coveringSeed``.
    package var shouldRunScreening: Bool {
        replayIteration == nil
            && screeningReplay == nil
            && screeningBudget > 0
    }

    /// Normalized idle timeout: `nil` when the configured value is non-positive or sentinel-large (``Int/max``), meaning "wait unbounded". Used by the preemptive checkers to distinguish a real timeout from an intentionally disabled one.
    package var resolvedIdleTimeoutMilliseconds: Int? {
        (idleTimeoutMilliseconds > 0 && idleTimeoutMilliseconds < Int.max) ? idleTimeoutMilliseconds : nil
    }

    /// Log configuration derived from the resolved settings, shared by all concurrent entry points.
    package var logConfiguration: ExhaustLog.Configuration {
        ExhaustLog.Configuration(
            isEnabled: suppressLogs == false,
            minimumLevel: logLevel,
            format: .keyValue
        )
    }

    /// Pushes the deadline back by `nanoseconds`, so that span does not count against the run's budget.
    ///
    /// Parsing stamps the deadline when it reads the settings, which is before the run is admitted at the ``LaneGate``. Time parked there is spent queueing behind other runs rather than probing, so the runners discount it once they hold their lanes. Without the discount a run admitted late reports a deadline it never got to use, having executed nothing.
    ///
    /// A deadline already saturated at ``UInt64/max`` stays there, and a run with no deadline is unaffected.
    package mutating func postponeDeadline(by nanoseconds: UInt64) {
        guard let deadline = deadlineNanoseconds else { return }
        let (postponed, overflow) = deadline.addingReportingOverflow(nanoseconds)
        deadlineNanoseconds = overflow ? .max : postponed
    }
}

// MARK: - Run Record

/// What a finished state machine run recorded, for the caller to turn into its report.
package struct StateMachineRunRecord {
    package let ledger: RunLedger
    package let hasExceededDeadline: Bool
    package let seed: UInt64?
    package let totalMilliseconds: Double
    package let screeningMilliseconds: Double
    package let reductionMilliseconds: Double
    /// The merged statistics of every reduction the run performed, or nil when none ran.
    package let reductionStats: ReductionStats?
    package let reductionWasCapped: Bool

    package init(
        ledger: RunLedger,
        hasExceededDeadline: Bool,
        seed: UInt64?,
        totalMilliseconds: Double,
        screeningMilliseconds: Double,
        reductionMilliseconds: Double,
        reductionStats: ReductionStats?,
        reductionWasCapped: Bool
    ) {
        self.ledger = ledger
        self.hasExceededDeadline = hasExceededDeadline
        self.seed = seed
        self.totalMilliseconds = totalMilliseconds
        self.screeningMilliseconds = screeningMilliseconds
        self.reductionMilliseconds = reductionMilliseconds
        self.reductionStats = reductionStats
        self.reductionWasCapped = reductionWasCapped
    }
}
