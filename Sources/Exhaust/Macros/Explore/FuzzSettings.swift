// Configuration options for `#explore(time:)` coverage-guided runs.
//
// Two types rather than one. The generator form and the spec form share four settings and differ in two, and a single enum made `.commandLimit` spellable on a generator, where it could only be reported as a run-time configuration error. Splitting moves that report to compile time. `ParsedPropertyFuzzSettings` stays the single reader of the shared four, so their handling cannot drift between the forms.
import ExhaustCore

/// Controls test behavior for `#explore(gen, time:)` coverage-guided runs, passed as variadic arguments.
///
/// The `time:` mode takes a distinct settings type from ``ExploreSettings`` because most of its knobs (replay of a whole fuzz run, budget-relative stopping) have no meaning under `directions:` mode, and the two modes are mutually exclusive at the type level.
///
/// Searching a `@StateMachine` spec takes ``StateMachineFuzzSettings`` instead, which adds the two settings that need command sequences to mean anything.
///
/// - Important: This mode is experimental. Its settings, report format, and search behavior may change in any release; every call site emits a build warning until the mode stabilizes.
public enum PropertyFuzzSettings: Sendable {
    /// A fixed seed for replaying a prior run (reproduction, benchmarking, regression).
    ///
    /// Accepts a raw `UInt64` or a Crockford Base32 string. The seed pins every decision the search makes: the screening rows, the random-sampling stream, each mutation choice, and, because reduction runs inline, the point in the attempt stream where each failure's classification feeds back. What the search observes between decisions is environmental: coverage signatures are read from process-global counters, and phase transitions are wall-clock cuts. A replay therefore reruns the same search from the same starting point and, given comparable time, rediscovers the same clusters. It does not reproduce an attempt-for-attempt identical log.
    ///
    /// - Important: Other tests running in parallel in the same process execute instrumented code during attempts and distort the coverage signal, and a replay that sees different coverage takes a different path. Marking the suite `.serialized` is not sufficient, because separate suites still run concurrently with each other. Run the target with `swift test --no-parallel`, or filter the run down to the single fuzz test. See <doc:CoverageGuidedFuzzing> for the full set of conditions.
    case replay(ReplaySeed)

    /// Silences issue reporting, log output, attachments, or all three for this run.
    ///
    /// Use `.suppress(.issueReporting)` when the run is expected to find failures and the test asserts on the returned ``FuzzReport`` instead. Generation and internal errors are not suppressed, because they signal a malfunction rather than the failures the caller is asserting on.
    case suppress(SuppressOption)

    /// Controls log verbosity for this run.
    ///
    /// Defaults to `.log(.error)` when omitted, so only error-level messages appear.
    case log(LogLevel)

    /// Stops the run as soon as its first fault is classified, instead of spending the remaining budget cataloging further distinct counterexamples.
    ///
    /// The failing input is still reduced before the run stops, so the report carries one reduced cluster and the recorded issue names a minimal counterexample. Use this where any failure fails the run and further faults would not change the outcome, such as a merge gate; keep the default full-duration run when the goal is as complete a fault inventory as the mode offers, because faults beyond the first are exactly what the remaining budget buys. The report's termination reads ``FuzzReport/Termination/firstFaultFound``.
    case failFast

    /// Skips the boundary-screening phase, so the search starts directly from random sampling.
    ///
    /// Screening probes covering-array rows built from each choice site's boundary values before any random search. On most properties those rows are the cheapest source of early faults and corpus seeds, so the default keeps them. Skip screening when boundary-shaped inputs cannot reach the property's interesting behavior — most commonly a sparse precondition that discards nearly every boundary row — or when comparing search strategies that must start from identical conditions, where screening would give one arm a head start the comparison is not measuring. The screening phase's budget flows to the remaining phases; nothing else about the search changes.
    case skipScreening

    /// Ends the run early once the search stops reaching new code, returning the unused budget instead of spending it.
    ///
    /// Saturation is judged from the run's own coverage statistics: the estimated probability that the next attempt reaches an edge nothing has reached yet, scoped to what this generator and property can actually cover. That is the same figure the report prints as "estimated chance the next attempt covers a new edge". Once it falls below 1 in 10,000, the run stops and the report's termination reads ``FuzzReport/Termination/coveragePlateau(unused:)``.
    ///
    /// Off by default, and worth understanding before switching on. Coverage saturation is not the same as having found every fault: a failure on an already-covered path stays reachable long after the last new edge, and on a sparse-precondition workload roughly a fifth of all detections arrived after coverage stopped growing. Use this where the budget is long, the machine is shared, and returning unspent time is worth more than the tail of the search. Keep the default where finding faults matters more than finishing early.
    case stopWhenSaturated
}

/// Controls test behavior for `#explore(Spec.self, mode:, time:)` coverage-guided runs, passed as variadic arguments.
///
/// Carries the same replay, suppression, log, and fail-fast settings as ``PropertyFuzzSettings``, plus the two that describe command sequences. Those two are absent from the generator form because a generator produces one value rather than a sequence of commands, so writing them there is a compile error.
///
/// - Important: This mode is experimental. Its settings, report format, and search behavior may change in any release; every call site emits a build warning until the mode stabilizes.
public enum StateMachineFuzzSettings: Sendable {
    /// A fixed seed for replaying a prior run (reproduction, benchmarking, regression).
    ///
    /// Accepts a raw `UInt64` or a Crockford Base32 string. The seed pins every decision the search makes: the screening rows, the random-sampling stream, each mutation choice, and, because reduction runs inline, the point in the attempt stream where each failure's classification feeds back. What the search observes between decisions is environmental: coverage signatures are read from process-global counters, and phase transitions are wall-clock cuts. A replay therefore reruns the same search from the same starting point and, given comparable time, rediscovers the same clusters. It does not reproduce an attempt-for-attempt identical log.
    ///
    /// - Important: Other tests running in parallel in the same process execute instrumented code during attempts and distort the coverage signal, and a replay that sees different coverage takes a different path. Marking the suite `.serialized` is not sufficient, because separate suites still run concurrently with each other. Run the target with `swift test --no-parallel`, or filter the run down to the single fuzz test. See <doc:CoverageGuidedFuzzing> for the full set of conditions.
    case replay(ReplaySeed)

    /// Silences issue reporting, log output, attachments, or all three for this run.
    ///
    /// Use `.suppress(.issueReporting)` when the run is expected to find failures and the test asserts on the returned ``FuzzReport`` instead. Generation and internal errors are not suppressed, because they signal a malfunction rather than the failures the caller is asserting on.
    case suppress(SuppressOption)

    /// Controls log verbosity for this run.
    ///
    /// Defaults to `.log(.error)` when omitted, so only error-level messages appear.
    case log(LogLevel)

    /// Stops the run as soon as its first fault is classified, instead of spending the remaining budget cataloging further distinct counterexamples.
    ///
    /// The failing command sequence is still reduced before the run stops, so the report carries one reduced cluster and the recorded issue names a minimal counterexample. Use this where any failure fails the run and further faults would not change the outcome, such as a merge gate; keep the default full-duration run when the goal is as complete a fault inventory as the mode offers, because faults beyond the first are exactly what the remaining budget buys. The report's termination reads ``FuzzReport/Termination/firstFaultFound``.
    case failFast

    /// Skips the boundary-screening phase, so the search starts directly from random sampling.
    ///
    /// Screening probes covering-array rows built from each choice site's boundary values before any random search. On most properties those rows are the cheapest source of early faults and corpus seeds, so the default keeps them. Skip screening when boundary-shaped inputs cannot reach the property's interesting behavior — most commonly a sparse precondition that discards nearly every boundary row — or when comparing search strategies that must start from identical conditions, where screening would give one arm a head start the comparison is not measuring. The screening phase's budget flows to the remaining phases; nothing else about the search changes.
    case skipScreening

    /// Ends the run early once the search stops reaching new code, returning the unused budget instead of spending it.
    ///
    /// Saturation is judged from the run's own coverage statistics: the estimated probability that the next attempt reaches an edge nothing has reached yet, scoped to what this generator and property can actually cover. That is the same figure the report prints as "estimated chance the next attempt covers a new edge". Once it falls below 1 in 10,000, the run stops and the report's termination reads ``FuzzReport/Termination/coveragePlateau(unused:)``.
    ///
    /// Off by default, and worth understanding before switching on. Coverage saturation is not the same as having found every fault: a failure on an already-covered path stays reachable long after the last new edge, and on a sparse-precondition workload roughly a fifth of all detections arrived after coverage stopped growing. Use this where the budget is long, the machine is shared, and returning unspent time is worth more than the tail of the search. Keep the default where finding faults matters more than finishing early.
    case stopWhenSaturated

    /// Limits the maximum number of commands per generated sequence.
    ///
    /// When omitted, sequences carry up to 40 commands. Pass this when the default produces sequences too short to reach deep state (for example, a bounded data structure whose accumulation faults require capacity-many operations without interruption), or to shorten sequences when each command is expensive. Values below 1 are a configuration error.
    case commandLimit(Int)

    /// Sets the number of concurrent lanes for `.tasks` specs.
    ///
    /// When omitted, `.tasks` specs run with two lanes. More lanes widen the space of interleavings each sequence can express, at the cost of spreading the same commands thinner across lanes. `.sequential` specs have no lanes, so they ignore this setting.
    case parallelize(lanes: ConcurrencyLevel)
}

// MARK: - Parsing

/// The fields both `time:` entry points read from their settings, extracted in one pass.
///
/// The spec path reaches this by converting its own settings to the shared three first, so the replay, suppression, and log fields are read in exactly one place for both forms.
struct ParsedPropertyFuzzSettings {
    /// The replay seed, or nil when the run should draw a random one.
    var seed: UInt64?
    /// The configuration error for a replay seed that carries no run seed (screening-row seeds), rendered verbatim into the run's termination.
    var invalidReplayMessage: String?
    var suppress = SuppressFlags()
    var logLevel: LogLevel = .error
    /// Whether the run stops at its first classified fault instead of cataloging further distinct counterexamples.
    var failFast = false
    /// Whether the boundary-screening phase is skipped, so the search starts from random sampling.
    var skipScreening = false
    /// Whether the run ends early once its discovery-probability estimate says coverage has saturated.
    var stopWhenSaturated = false

    init(_ settings: [PropertyFuzzSettings]) {
        for setting in settings {
            switch setting {
                case let .replay(replaySeed):
                    // A fuzz run replays the whole search from its root seed, so only sampling forms apply here. A screening seed addresses a covering-array row this runner cannot replay, and honoring its seed digits as a run seed would silently run a different search than the one the seed names.
                    switch replaySeed.resolve() {
                        case let .sampling(resolvedSeed, _):
                            seed = resolvedSeed
                        case .valueScreening, .specScreening, nil:
                            invalidReplayMessage = "Invalid replay seed for #explore(time:): \(replaySeed). Pass the run seed from a prior report."
                    }
                case let .suppress(option):
                    suppress.apply(option)
                case let .log(level):
                    logLevel = level
                case .failFast:
                    failFast = true
                case .skipScreening:
                    skipScreening = true
                case .stopWhenSaturated:
                    stopWhenSaturated = true
            }
        }
    }
}

/// The spec path's settings, split into the two fields only it understands and the remainder the shared core reads.
///
/// The command-sequence settings must not travel further: the core takes ``PropertyFuzzSettings``, which has no case to carry them. Validation of the consumed fields lives here too, so both time dispatches (sync and async) reject the same configurations.
struct ParsedStateMachineFuzzSettings {
    /// The per-sequence command cap; nil when unset, in which case the runner applies ``FuzzTunables/specDefaultCommandLimit``.
    var commandLimit: Int?
    /// The lane count for `.tasks` specs; nil when unset.
    var parallelize: ConcurrencyLevel?
    /// The settings to forward to the shared core.
    var coreSettings: [PropertyFuzzSettings] = []
    /// The shared fields, read through the one parser both forms use.
    let shared: ParsedPropertyFuzzSettings

    /// Non-nil when a consumed setting is invalid; the dispatch returns an empty report with this termination instead of running.
    var invalidConfiguration: FuzzReport.Termination? {
        guard let commandLimit, commandLimit < 1 else {
            return nil
        }
        return .invalidConfiguration(".commandLimit must be at least 1, got \(commandLimit).")
    }

    init(_ settings: [StateMachineFuzzSettings]) {
        for setting in settings {
            switch setting {
                case let .replay(replaySeed):
                    coreSettings.append(.replay(replaySeed))
                case let .suppress(option):
                    coreSettings.append(.suppress(option))
                case let .log(level):
                    coreSettings.append(.log(level))
                case .failFast:
                    coreSettings.append(.failFast)
                case .skipScreening:
                    coreSettings.append(.skipScreening)
                case .stopWhenSaturated:
                    coreSettings.append(.stopWhenSaturated)
                case let .commandLimit(limit):
                    commandLimit = limit
                case let .parallelize(lanes):
                    parallelize = lanes
            }
        }
        shared = ParsedPropertyFuzzSettings(coreSettings)
    }
}
