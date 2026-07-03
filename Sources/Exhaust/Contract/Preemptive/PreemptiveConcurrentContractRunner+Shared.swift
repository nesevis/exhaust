// Shared types for the synchronous and async preemptive contract runners.
import ExhaustCore
import IssueReporting

/// Groups shared types for the synchronous and async preemptive contract runners.
enum Preemptive {
    /// Captures the result of one preemptive concurrent execution probe.
    enum Outcome<Spec: ContractSpecBase> {
        /// The execution is consistent with some valid sequential ordering.
        case passed
        /// A lane or the drain loop did not finish within the idle timeout.
        case timedOut(concurrentSpec: Spec?)
        /// A command threw, an invariant failed, or an ObjC exception was caught before response comparison.
        case failed(concurrentSpec: Spec?)
        /// The oracle detected a state divergence from the sequential reference. Per-lane observed responses are available for linearizability analysis.
        case oracleMismatch(laneResponses: [[ObservedResponse<Spec.Command>]], concurrentSpec: Spec)

        var concurrentSpec: Spec? {
            switch self {
                case .passed: nil
                case let .timedOut(concurrentSpec): concurrentSpec
                case let .failed(concurrentSpec): concurrentSpec
                case let .oracleMismatch(_, concurrentSpec): concurrentSpec
            }
        }

        var laneResponses: [[ObservedResponse<Spec.Command>]]? {
            switch self {
                case let .oracleMismatch(laneResponses, _): laneResponses
                default: nil
            }
        }
    }
}

// MARK: - Interleaving Space Warning

/// Emits a runtime warning when the worst-case linearizability search space exceeds 1 billion interleavings.
///
/// The worst case distributes `commandLimit` commands as evenly as possible across `laneCount` lanes, giving multinomial(commandLimit; sizes) interleavings. The DFS is exhaustive, so a large search space means each linearizability check can be slow.
func warnIfInterleavingSpaceIsLarge(
    commandLimit: Int,
    laneCount: Int,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
) {
    guard laneCount >= 2 else {
        return
    }
    let interleavings = worstCaseInterleavings(totalCommands: commandLimit, lanes: laneCount)
    guard interleavings > PreemptiveReduction.interleavingWarningThreshold else {
        return
    }
    let millions = interleavings / 1_000_000
    reportIssue(
        "Worst-case linearizability search space is ~\(millions)M interleavings (commandLimit=\(commandLimit), lanes=\(laneCount)). Each oracle-flagged probe runs an exhaustive DFS over this space. Reduce .commandLimit or .concurrent level to improve performance.",
        severity: .warning,
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
    )
}

// MARK: - Timeout Fraction Warning

/// Emits a runtime warning when timed-out probes reach ``PreemptiveReduction/timeoutWarningFraction`` of the configured budget.
///
/// A timed-out probe counts as a pass so a contended host or a hanging system does not produce a false failure, but a high timeout rate means most of the budget produced no signal. The warning reports the rate so a silently-passing run that never actually exercised the system is still visible. Call this on the test's own thread after the pipeline returns, not from inside the dispatched work, so the issue attaches to the running test.
func warnIfTimeoutFractionHigh(
    timedOutProbes: Int,
    totalBudget: UInt64,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
) {
    guard totalBudget > 0, timedOutProbes > 0 else {
        return
    }
    let fraction = Double(timedOutProbes) / Double(totalBudget)
    guard fraction >= PreemptiveReduction.timeoutWarningFraction else {
        return
    }
    let percentage = Int((fraction * 100).rounded())
    reportIssue(
        "\(timedOutProbes) of \(totalBudget) budgeted probes timed out (\(percentage)%). Timed-out probes count as passes, so this run may have passed without exercising the system. A saturated machine, an idle timeout set too low, or a genuinely hanging command can cause this. Raise .idleTimeoutMs, reduce parallelism, or check for a hang.",
        severity: .warning,
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
    )
}

/// Worst-case multinomial coefficient for `totalCommands` distributed as evenly as possible across `lanes`. Returns `Int.max` on overflow.
private func worstCaseInterleavings(totalCommands: Int, lanes: Int) -> Int {
    let base = totalCommands / lanes
    let extra = totalCommands % lanes
    var sizes: [Int] = []
    for lane in 0 ..< lanes {
        sizes.append(base + (lane < extra ? 1 : 0))
    }
    var result = 1
    var remaining = totalCommands
    for size in sizes {
        for pick in 1 ... size {
            let (product, overflow) = result.multipliedReportingOverflow(by: remaining)
            if overflow {
                return Int.max
            }
            result = product / pick
            remaining -= 1
        }
    }
    return result
}

// MARK: - Realized Completion Order

/// Merges per-lane observations into the order the commands actually returned, by ascending return timestamp.
///
/// This replaces the shared, locked completion log the lanes used to append to: a lock on the command path serializes the lanes between commands, and lock acquisition order can itself invert the true return order under contention. Sorting post-hoc on the per-command timestamps has neither problem. Observations without an interval sort last; the runners always record intervals, so that arm is defensive.
func realizedCompletionOrder<Command>(
    of laneResponses: [[ObservedResponse<Command>]]
) -> [ObservedResponse<Command>] {
    laneResponses
        .joined()
        .sorted { ($0.interval?.returnTime ?? .max) < ($1.interval?.returnTime ?? .max) }
}

// MARK: - Response Matching

/// Whether a replayed command result matches an observed response, using the same rule as ``LinearizabilityChecker``: skip flags must agree, and non-skipped return values must be structurally equal. Shared by the synchronous and async preemptive witness checks so the cheap realized-order replay and the full interleaving search never disagree on what "the same response" means.
func preemptiveResponseMatches(
    observed: ObservedOutcome,
    replayValue: Any?,
    replaySkipped: Bool
) -> Bool {
    if observed.isSkipped != replaySkipped {
        return false
    }
    switch (observed.returnValue, replayValue) {
        case (nil, nil):
            return true
        case let (observedValue?, replayedValue?):
            return structurallyEqual(observedValue, replayedValue)
        default:
            return false
    }
}
