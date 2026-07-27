/// Tests whether a concurrent execution's observed responses are consistent with some valid sequential ordering.
///
/// The checker enumerates valid interleavings that preserve per-lane command order and measured real-time precedence. For each ordering, it replays the commands via the caller's closures, compares per-step responses via ``structurallyEqual(_:_:)``, and checks the oracle against the concurrent execution's final state. If any ordering produces matching responses and passes the oracle, the execution is linearizable.
///
/// Two ordering constraints bound the search. Each lane's own command order is always preserved. When ``ObservedInterval`` timestamps are available, cross-lane returns-before edges are enforced as well: a command whose measured return precedes another command's measured call must be ordered first (Herlihy and Wing's real-time condition). Without the second constraint the checker would accept histories where a lane observes state that a completed command on another lane had already overwritten: a stale read explained away by reordering non-overlapping commands. The intervals also prune the search: every enforced edge removes candidate interleavings from the DFS.
///
/// Enforcement checks only lane heads: within a lane, commands run sequentially, so per-lane return times are non-decreasing and the head holds the lane's earliest unplaced return. If any unplaced command's return precedes a candidate's call, that lane's head's return does too, so the head guard rejects every real-time violation (see ``candidateRespectsRealTime(laneIndex:cursor:cursors:)``).
///
/// On failure, the checker reports the ``Witness``: the concurrent command whose observed response no ordering reproduces. This pins a response-level violation to a single command, the case the final-state diff cannot show, because the end state may coincidentally match a valid ordering even though no ordering yields the observed return value. When divergence is only in the final state (the oracle), there is no command witness and ``Witness`` is `nil`; that case is already visible in the expected-versus-actual state diff.
///
/// Replay is asynchronous only. A synchronous caller bridges once around the whole check: the search runs after the concurrent phase, so the bridge adds nothing to the command path the lanes race on, and one bridge per check costs less than maintaining a synchronous twin of the exponential search.
///
/// The checker is deliberately non-generic: it stores per-lane ``ObservedOutcome`` arrays and addresses commands by `(laneIndex, commandIndex)` coordinates through the replay closure, so the exponential search compiles as concrete code under this module's whole-module optimization instead of an unspecialized generic. The commands themselves stay with the caller.
///
/// - SeeAlso: ``LinearizabilityChecker/Result/passesTheProbe``, which is the question every caller actually asks of a verdict.
package struct LinearizabilityChecker: @unchecked Sendable {
    /// The response from replaying a single command on a fresh sequential instance.
    package struct ReplayResponse {
        package let returnValue: Any?
        package let isSkipped: Bool

        package init(returnValue: Any?, isSkipped: Bool) {
            self.returnValue = returnValue
            self.isSkipped = isSkipped
        }
    }

    /// The concurrent command whose observed response no valid ordering reproduces, addressed by its position in ``laneOutcomes`` (`laneIndex` is the outer index, `commandIndex` the per-lane offset). The caller maps these coordinates back to a renderable command.
    package struct Witness: Sendable {
        package let laneIndex: Int
        package let commandIndex: Int
    }

    /// Result of a linearizability check.
    package enum Result {
        case linearizable
        /// The search spent its replay budget before it could either find an explanation or rule every one out. Callers treat it as a pass, because an unfinished search must never be reported as a counterexample, and count it, because a run whose searches were all abandoned passed without judging anything.
        case abandoned
        case notLinearizable(witness: Witness?, failureDescription: String?)
    }

    package let laneOutcomes: [[ObservedOutcome]]

    /// Per-lane measured execution spans, aligned index-for-index with ``laneOutcomes``. A nil entry means the caller had no timing data for that command; such commands are treated as overlapping everything, so missing data weakens the real-time constraint but never rejects a valid ordering.
    package let laneIntervals: [[ObservedInterval?]]

    package init(laneOutcomes: [[ObservedOutcome]], laneIntervals: [[ObservedInterval?]]? = nil) {
        self.laneOutcomes = laneOutcomes
        self.laneIntervals = laneIntervals ?? laneOutcomes.map { lane in Array(repeating: nil, count: lane.count) }
    }

    /// A command placed at a position in a candidate ordering, retaining its source coordinates so the witness can name it and the replay closure can locate the command. Stored as an index pair to keep the DFS working array (``SearchState/currentOrdering``) compact.
    private struct Placed {
        let laneIndex: Int
        let commandIndex: Int
    }

    // MARK: - Search State

    private struct SearchState {
        var cursors: [Int]
        var currentOrdering: [Placed]
        var closestMatchDepth: Int = -1
        var closestPlaced: Placed?
        /// Command replays left before the search abandons. See ``PreemptiveReduction/linearizabilitySearchReplayBudget``.
        var replayBudget: Int
        /// What one `replayPrefix` call costs against the budget, in command-replay units.
        let prefixReplayCost: Int
        /// Set when the budget ran out, so the verdict resolves as linearizable rather than reporting a violation the search never finished looking for.
        var abandoned = false

        init(laneCount: Int, totalCommands: Int, prefixLength: Int, replayBudget: Int) {
            cursors = Array(repeating: 0, count: laneCount)
            currentOrdering = []
            currentOrdering.reserveCapacity(totalCommands)
            self.replayBudget = replayBudget
            // A prefix replay builds a fresh spec, applies setup, and runs every prefix command, so it costs at least one command replay even when the prefix is empty. Leaving it uncharged would let a long prefix multiply the search's real cost by a factor the budget cannot see.
            prefixReplayCost = max(1, prefixLength)
        }

        /// Charges one command replay, reporting whether the search may continue.
        mutating func chargeReplay() -> Bool {
            charge(1)
        }

        /// Charges one prefix replay, reporting whether the search may continue.
        mutating func chargePrefixReplay() -> Bool {
            charge(prefixReplayCost)
        }

        private mutating func charge(_ cost: Int) -> Bool {
            guard replayBudget >= cost else {
                abandoned = true
                return false
            }
            replayBudget -= cost
            return true
        }
    }

    // MARK: - Check

    /// Checks linearizability with incremental verification, folded into the DFS: each placed command is replayed immediately and the subtree is pruned on response mismatch.
    ///
    /// - Parameters:
    ///   - prefixLength: How many prefix commands `replayPrefix` runs, so the search budget can charge a prefix replay for the work it actually does.
    ///   - replayPrefix: Replays all prefix commands on a fresh sequential instance. Returns `false` if any prefix command fails. The closure captures its own prefix data.
    ///   - replayCommand: Replays the concurrent command at the given `(laneIndex, commandIndex)` coordinates on the sequential instance. Returns `nil` if the command threw a non-skip error.
    ///   - checkOracle: Checks whether the sequential instance's final state matches the concurrent execution's final state.
    ///   - failureDescription: Produces a human-readable description of the expected state on failure.
    package func check(
        prefixLength: Int,
        replayPrefix: () async -> Bool,
        replayCommand: (_ laneIndex: Int, _ commandIndex: Int) async -> ReplayResponse?,
        checkOracle: () async -> Bool,
        failureDescription: () -> String?
    ) async -> Result {
        let laneCount = laneOutcomes.count
        let totalCommands = laneOutcomes.reduce(0) { $0 + $1.count }
        var state = SearchState(
            laneCount: laneCount,
            totalCommands: totalCommands,
            prefixLength: prefixLength,
            replayBudget: PreemptiveReduction.linearizabilitySearchReplayBudget
        )

        let found = await searchIncrementally(
            totalCommands: totalCommands,
            state: &state,
            replayPrefix: replayPrefix,
            replayCommand: replayCommand,
            checkOracle: checkOracle
        )

        return makeResult(
            found: found,
            abandoned: state.abandoned,
            closestMatchDepth: state.closestMatchDepth,
            closestPlaced: state.closestPlaced,
            failureDescription: failureDescription
        )
    }

    // MARK: - Incremental Search

    private func replayToDepth(
        _ depth: Int,
        state: inout SearchState,
        replayPrefix: () async -> Bool,
        replayCommand: (Int, Int) async -> ReplayResponse?
    ) async -> Bool {
        guard state.chargePrefixReplay() else {
            return false
        }
        guard await replayPrefix() else { return false }
        for index in 0 ..< depth {
            guard state.chargeReplay() else { return false }
            let placed = state.currentOrdering[index]
            guard await replayCommand(placed.laneIndex, placed.commandIndex) != nil else { return false }
        }
        return true
    }

    private func searchIncrementally(
        totalCommands: Int,
        state: inout SearchState,
        replayPrefix: () async -> Bool,
        replayCommand: (Int, Int) async -> ReplayResponse?,
        checkOracle: () async -> Bool
    ) async -> Bool {
        guard state.abandoned == false else { return false }
        let depth = state.currentOrdering.count

        if depth == totalCommands {
            if depth == 0 {
                guard await replayPrefix() else { return false }
            }
            let oraclePassed = await checkOracle()
            if oraclePassed == false {
                updateClosest(depth: depth, placed: nil, closestMatchDepth: &state.closestMatchDepth, closestPlaced: &state.closestPlaced)
            }
            return oraclePassed
        }

        var childrenTried = 0

        for laneIndex in 0 ..< laneOutcomes.count {
            let cursor = state.cursors[laneIndex]
            guard cursor < laneOutcomes[laneIndex].count else { continue }
            guard candidateRespectsRealTime(laneIndex: laneIndex, cursor: cursor, cursors: state.cursors) else { continue }

            let observed = laneOutcomes[laneIndex][cursor]

            if childrenTried > 0 || depth == 0 {
                guard await replayToDepth(depth, state: &state, replayPrefix: replayPrefix, replayCommand: replayCommand) else {
                    if state.abandoned { return false }
                    continue
                }
            }
            childrenTried += 1

            let placed = Placed(laneIndex: laneIndex, commandIndex: cursor)

            guard state.chargeReplay() else { return false }
            guard let replay = await replayCommand(laneIndex, cursor) else {
                updateClosest(depth: depth, placed: placed, closestMatchDepth: &state.closestMatchDepth, closestPlaced: &state.closestPlaced)
                continue
            }

            if stepMismatches(observed: observed, replay: replay) {
                updateClosest(depth: depth, placed: placed, closestMatchDepth: &state.closestMatchDepth, closestPlaced: &state.closestPlaced)
                continue
            }

            if observed.isSkipped == false, responsesMatch(observed: observed, replay: replay) == false {
                updateClosest(depth: depth, placed: placed, closestMatchDepth: &state.closestMatchDepth, closestPlaced: &state.closestPlaced)
                continue
            }

            state.cursors[laneIndex] += 1
            state.currentOrdering.append(placed)

            let found = await searchIncrementally(
                totalCommands: totalCommands,
                state: &state,
                replayPrefix: replayPrefix,
                replayCommand: replayCommand,
                checkOracle: checkOracle
            )

            state.currentOrdering.removeLast()
            state.cursors[laneIndex] -= 1

            if found { return true }
        }

        return false
    }

    // MARK: - Shared Helpers

    /// Whether placing the candidate command next would respect measured real-time precedence: no unplaced command's return may precede the candidate's call (an operation can be linearized next only if it is minimal in the returns-before order, per Wing and Gong).
    ///
    /// Checking each lane's head is sufficient: per-lane return times are non-decreasing, so if any unplaced command in a lane returned before the candidate's call, that lane's head did too. Commands without an interval impose and receive no constraint.
    ///
    /// Rejections here need no `closestPlaced` bookkeeping: the candidate is not a response mismatch, it is simply not permitted at this position, and it remains reachable through orderings that place the earlier-returning command first.
    private func candidateRespectsRealTime(laneIndex: Int, cursor: Int, cursors: [Int]) -> Bool {
        guard let candidateCall = laneIntervals[laneIndex][cursor]?.callTime else {
            return true
        }
        for otherLane in 0 ..< laneIntervals.count where otherLane != laneIndex {
            let otherCursor = cursors[otherLane]
            guard otherCursor < laneIntervals[otherLane].count else { continue }
            if let otherReturn = laneIntervals[otherLane][otherCursor]?.returnTime, otherReturn < candidateCall {
                return false
            }
        }
        return true
    }

    /// Whether the replay disagrees with the observation about *whether the command ran at all*.
    ///
    /// A skip is an observable response, so the two must agree: a command that skipped concurrently must skip in the replay, and one that ran must run. Disagreement rejects the placement exactly as a differing return value does, and a history no ordering can match on skips is reported as non-linearizable.
    ///
    /// This is what makes a skip guard that reads the model unusable under thread-based execution. Each lane runs on its own spec instance, whose model carries the prefix and nothing another lane did, so a guard like `guard model.isEmpty == false` skips on lanes that would not have skipped had the model been whole. The replay instance has the whole model, runs the command, and no ordering can explain the observed skips — a correct system under test reported as a violation. A guard that reads the system under test asks the shared object the lanes actually raced on, and the replay reproduces its answer.
    private func stepMismatches(observed: ObservedOutcome, replay: ReplayResponse) -> Bool {
        observed.isSkipped != replay.isSkipped
    }

    private func responsesMatch(observed: ObservedOutcome, replay: ReplayResponse) -> Bool {
        switch (observed.returnValue, replay.returnValue) {
            case (nil, nil):
                return true
            case let (observedValue?, replayValue?):
                return structurallyEqual(observedValue, replayValue)
            default:
                return false
        }
    }

    /// Records the DFS node at the deepest divergence point. `placed` is `nil` when divergence is at the oracle (all commands matched but the final state differed), in which case there is no command-level witness.
    private func updateClosest(
        depth: Int,
        placed: Placed?,
        closestMatchDepth: inout Int,
        closestPlaced: inout Placed?
    ) {
        if depth > closestMatchDepth {
            closestMatchDepth = depth
            closestPlaced = placed
        }
    }

    /// Builds the verdict. When the closest divergence is at the oracle level (`closestPlaced` is `nil`), there is no command witness — the failure is visible only in the expected-versus-actual state diff.
    ///
    /// An abandoned search (the replay budget ran out before every ordering was tried) reports ``Result/abandoned`` rather than a violation: the search failed to find an explanation, but it also failed to rule one out, and reporting an unfinished search as a violation would manufacture counterexamples out of configurations that are merely too large. Callers pass the probe and tally the abandonment, so the run can warn about what it did not judge.
    private func makeResult(found: Bool, abandoned: Bool, closestMatchDepth: Int, closestPlaced: Placed?, failureDescription: () -> String?) -> Result {
        guard found == false else {
            return .linearizable
        }
        guard abandoned == false else {
            return .abandoned
        }
        guard closestMatchDepth >= 0, let placed = closestPlaced else {
            return .notLinearizable(witness: nil, failureDescription: failureDescription())
        }
        return .notLinearizable(witness: Witness(laneIndex: placed.laneIndex, commandIndex: placed.commandIndex), failureDescription: failureDescription())
    }
}

// MARK: - Verdict Questions

package extension LinearizabilityChecker.Result {
    /// Whether the verdict lets the probe stand.
    ///
    /// Two verdicts do, for different reasons: a search that found an explaining ordering, and a search that ran out of replay budget before it could rule every ordering out. Only a completed search that rejected every ordering fails the probe. Callers ask this rather than matching cases, because treating the abandoned verdict as a failure would manufacture counterexamples out of configurations that are merely too large.
    var passesTheProbe: Bool {
        switch self {
            case .linearizable, .abandoned:
                return true
            case .notLinearizable:
                return false
        }
    }

    /// Whether the search stopped for want of replay budget. Runners tally this so a run can warn about the probes it passed without judging.
    var isAbandoned: Bool {
        switch self {
            case .abandoned:
                return true
            case .linearizable, .notLinearizable:
                return false
        }
    }
}
