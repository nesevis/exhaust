// Runtime warnings shared by the task-based and thread-based runners.
//
// Every warning here guards the same failure shape: a concurrent run that passes while having judged less than it appears to. Each runner calls these on the test's own thread after its pipeline returns, so the issue attaches to the running test.
import ExhaustCore
import IssueReporting

// MARK: - Interleaving Space Warning

/// Emits a runtime warning when the worst-case linearizability search space exceeds ``ConcurrentSpecTunables/interleavingWarningThreshold``.
///
/// The worst case distributes `commandLimit` commands as evenly as possible across `laneCount` lanes, giving multinomial(commandLimit; sizes) interleavings. The message reports the command-replay cost rather than the ordering count alone, because the replay figure is the one that predicts wall-clock time: the DFS replays the prefix once per complete ordering and executes every command in it, so an unpruned search costs orderings times commands.
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
    guard interleavings > ConcurrentSpecTunables.interleavingWarningThreshold else {
        return
    }
    let (replays, replaysOverflowed) = interleavings.multipliedReportingOverflow(by: commandLimit)
    let replayText = replaysOverflowed ? "more than \(renderMagnitude(Int.max))" : "up to \(renderMagnitude(replays))"
    // The abandonment sentence only appears when the worst case actually exceeds the search budget; near the threshold a check is slow but still complete, and claiming abandonment there would overstate.
    let exceedsSearchBudget = replaysOverflowed || replays > ConcurrentSpecTunables.linearizabilitySearchReplayBudget
    let consequence = exceedsSearchBudget
        ? "Searches that exceed \(ConcurrentSpecTunables.linearizabilitySearchReplayBudget) replays are abandoned and reported as linearizable, so races may go undetected at this configuration."
        : "Each oracle-flagged probe runs an exhaustive DFS over this space, so checks can be slow."
    reportWarning(
        """
        Worst-case linearizability search space is \(renderMagnitude(interleavings)) interleavings (commandLimit=\(commandLimit), lanes=\(laneCount)), costing \(replayText) command replays per oracle-flagged probe. \
        \(consequence) \
        Reduce .commandLimit or .parallelize to bring the search back within budget.
        """,
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
    )
}

// MARK: - Timeout Fraction Warning

/// Emits a runtime warning when timed-out probes reach ``ConcurrentSpecTunables/timeoutWarningFraction`` of attempted probes.
///
/// A timed-out probe counts as a pass so a contended host or a hanging system does not produce a false failure, but a high timeout rate means most attempted probes produced no signal. The warning reports the rate so a run that never exercised the system does not pass silently.
func warnIfTimeoutFractionHigh(
    timedOutProbes: Int,
    totalProbes: Int,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
) {
    guard totalProbes > 0, timedOutProbes > 0 else {
        return
    }
    let fraction = Double(timedOutProbes) / Double(totalProbes)
    guard fraction >= ConcurrentSpecTunables.timeoutWarningFraction else {
        return
    }
    let percentage = Int((fraction * 100).rounded())
    reportWarning(
        "\(timedOutProbes) of \(totalProbes) probes timed out (\(percentage)%). Timed-out probes count as passes, so this run may have passed without exercising the system. A saturated machine, an idle timeout set too low, or a genuinely hanging command can cause this. Raise .idleTimeout, reduce parallelism, or check for a hang.",
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
    )
}

// MARK: - Abandoned Search Warning

/// Emits a runtime warning when any interleaving search spent its replay budget without reaching a verdict.
///
/// An abandoned search passes its probe, because an unfinished search must never be reported as a counterexample. That makes it silent by construction: a run whose searches were all abandoned reports success while having judged nothing. The count is what distinguishes "no race here" from "the search never finished looking", so it is surfaced rather than logged.
func warnIfSearchesWereAbandoned(
    abandonedSearches: Int,
    totalProbes: Int,
    fileID: StaticString,
    filePath: StaticString,
    line: UInt,
    column: UInt
) {
    guard abandonedSearches > 0 else {
        return
    }
    reportWarning(
        "Abandoned the interleaving search on \(abandonedSearches) of \(totalProbes) probes after it exceeded \(ConcurrentSpecTunables.linearizabilitySearchReplayBudget) command replays. An abandoned search passes its probe, so a race in those sequences went undetected. Reduce .commandLimit or .parallelize to bring the search back within budget.",
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
    )
}

/// Renders a search-space count at the magnitude a reader can act on: exact below a million, then one significant digit and a power of ten.
///
/// Past a million the trailing digits name no decision the reader can make, and the configurations this warning fires on reach 17 digits, which is harder to read in a terminal than `~3e17`.
private func renderMagnitude(_ count: Int) -> String {
    guard count >= 1_000_000 else {
        return "\(count)"
    }
    var leadingDigit = count
    var exponent = 0
    while leadingDigit >= 10 {
        leadingDigit /= 10
        exponent += 1
    }
    return "~\(leadingDigit)e\(exponent)"
}

/// Worst-case multinomial coefficient for `totalCommands` distributed as evenly as possible across `lanes`. Returns `Int.max` on overflow.
///
/// A lane's size is zero whenever there are fewer commands than lanes, which a caller reaches with something like `.parallelize(lanes: .three), .commandLimit(2)`. Such a lane contributes a factor of one and must be skipped rather than entered: `1 ... 0` is not a range.
private func worstCaseInterleavings(totalCommands: Int, lanes: Int) -> Int {
    let base = totalCommands / lanes
    let extra = totalCommands % lanes
    var sizes: [Int] = []
    for lane in 0 ..< lanes {
        sizes.append(base + (lane < extra ? 1 : 0))
    }
    var result = 1
    var remaining = totalCommands
    for size in sizes where size > 0 {
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
