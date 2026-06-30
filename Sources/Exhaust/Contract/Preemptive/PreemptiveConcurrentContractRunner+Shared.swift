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
    for size in sizes where size > 1 {
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

// MARK: - Response Matching

/// Whether a replayed command result matches an observed response, using the same rule as ``LinearizabilityChecker``: skip flags must agree, and non-skipped return values must be structurally equal. Shared by the synchronous and async preemptive witness checks so the cheap realized-order replay and the full interleaving search never disagree on what "the same response" means.
func preemptiveResponseMatches(
    observed: ObservedResponse<some Any>.Outcome,
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
