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
/// Both synchronous and asynchronous replay are supported. The interleaving search and response comparison are shared; only the replay-and-verify step differs.
///
/// The checker is deliberately non-generic: it stores per-lane ``ObservedOutcome`` arrays and addresses commands by `(laneIndex, commandIndex)` coordinates through the replay closure, so the exponential search compiles as concrete code under this module's whole-module optimization instead of an unspecialized generic. The commands themselves stay with the caller.
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

    // MARK: - Synchronous

    /// Checks linearizability using synchronous replay closures with incremental verification.
    ///
    /// Folds verification into the DFS: each placed command is replayed immediately and the subtree is pruned on response mismatch.
    ///
    /// - Parameters:
    ///   - replayPrefix: Replays all prefix commands on a fresh sequential instance. Returns `false` if any prefix command fails. The closure captures its own prefix data.
    ///   - replayCommand: Replays the concurrent command at the given `(laneIndex, commandIndex)` coordinates on the sequential instance. Returns `nil` if the command threw a non-skip error.
    ///   - checkOracle: Checks whether the sequential instance's final state matches the concurrent execution's final state.
    ///   - failureDescription: Produces a human-readable description of the expected state on failure.
    package func check(
        replayPrefix: () -> Bool,
        replayCommand: (_ laneIndex: Int, _ commandIndex: Int) -> ReplayResponse?,
        checkOracle: () -> Bool,
        failureDescription: () -> String?
    ) -> Result {
        let laneCount = laneOutcomes.count
        let totalCommands = laneOutcomes.reduce(0) { $0 + $1.count }
        var state = SearchState(laneCount: laneCount, totalCommands: totalCommands)

        let found = searchIncrementally(
            totalCommands: totalCommands,
            state: &state,
            replayPrefix: replayPrefix,
            replayCommand: replayCommand,
            checkOracle: checkOracle
        )

        return makeResult(found: found, closestMatchDepth: state.closestMatchDepth, closestPlaced: state.closestPlaced, failureDescription: failureDescription)
    }

    // MARK: - Search State

    private struct SearchState {
        var cursors: [Int]
        var currentOrdering: [Placed]
        var closestMatchDepth: Int = -1
        var closestPlaced: Placed?

        init(laneCount: Int, totalCommands: Int) {
            cursors = Array(repeating: 0, count: laneCount)
            currentOrdering = []
            currentOrdering.reserveCapacity(totalCommands)
        }
    }

    // MARK: - Incremental Search

    private func replayToDepth(
        _ depth: Int,
        currentOrdering: [Placed],
        replayPrefix: () -> Bool,
        replayCommand: (Int, Int) -> ReplayResponse?
    ) -> Bool {
        guard replayPrefix() else { return false }
        for index in 0 ..< depth {
            let placed = currentOrdering[index]
            guard replayCommand(placed.laneIndex, placed.commandIndex) != nil else { return false }
        }
        return true
    }

    private func searchIncrementally(
        totalCommands: Int,
        state: inout SearchState,
        replayPrefix: () -> Bool,
        replayCommand: (Int, Int) -> ReplayResponse?,
        checkOracle: () -> Bool
    ) -> Bool {
        let depth = state.currentOrdering.count

        if depth == totalCommands {
            if depth == 0 {
                guard replayPrefix() else { return false }
            }
            let oraclePassed = checkOracle()
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
                guard replayToDepth(depth, currentOrdering: state.currentOrdering, replayPrefix: replayPrefix, replayCommand: replayCommand) else {
                    continue
                }
            }
            childrenTried += 1

            let placed = Placed(laneIndex: laneIndex, commandIndex: cursor)

            guard let replay = replayCommand(laneIndex, cursor) else {
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

            let found = searchIncrementally(
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

    // MARK: - Asynchronous

    /// Checks linearizability using asynchronous replay closures with incremental verification.
    ///
    /// Async equivalent of ``check(replayPrefix:replayCommand:checkOracle:failureDescription:)``. Folds verification into the DFS with pruning on response mismatch.
    package func checkAsync(
        replayPrefix: () async -> Bool,
        replayCommand: (_ laneIndex: Int, _ commandIndex: Int) async -> ReplayResponse?,
        checkOracle: () async -> Bool,
        failureDescription: () -> String?
    ) async -> Result {
        let laneCount = laneOutcomes.count
        let totalCommands = laneOutcomes.reduce(0) { $0 + $1.count }
        var state = SearchState(laneCount: laneCount, totalCommands: totalCommands)

        let found = await searchIncrementallyAsync(
            totalCommands: totalCommands,
            state: &state,
            replayPrefix: replayPrefix,
            replayCommand: replayCommand,
            checkOracle: checkOracle
        )

        return makeResult(found: found, closestMatchDepth: state.closestMatchDepth, closestPlaced: state.closestPlaced, failureDescription: failureDescription)
    }

    // MARK: - Async Incremental Search

    private func replayToDepthAsync(
        _ depth: Int,
        currentOrdering: [Placed],
        replayPrefix: () async -> Bool,
        replayCommand: (Int, Int) async -> ReplayResponse?
    ) async -> Bool {
        guard await replayPrefix() else { return false }
        for index in 0 ..< depth {
            let placed = currentOrdering[index]
            guard await replayCommand(placed.laneIndex, placed.commandIndex) != nil else { return false }
        }
        return true
    }

    private func searchIncrementallyAsync(
        totalCommands: Int,
        state: inout SearchState,
        replayPrefix: () async -> Bool,
        replayCommand: (Int, Int) async -> ReplayResponse?,
        checkOracle: () async -> Bool
    ) async -> Bool {
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
                guard await replayToDepthAsync(depth, currentOrdering: state.currentOrdering, replayPrefix: replayPrefix, replayCommand: replayCommand) else {
                    continue
                }
            }
            childrenTried += 1

            let placed = Placed(laneIndex: laneIndex, commandIndex: cursor)

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

            let found = await searchIncrementallyAsync(
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
    private func makeResult(found: Bool, closestMatchDepth: Int, closestPlaced: Placed?, failureDescription: () -> String?) -> Result {
        guard found == false else {
            return .linearizable
        }
        guard closestMatchDepth >= 0, let placed = closestPlaced else {
            return .notLinearizable(witness: nil, failureDescription: failureDescription())
        }
        return .notLinearizable(witness: Witness(laneIndex: placed.laneIndex, commandIndex: placed.commandIndex), failureDescription: failureDescription())
    }
}
