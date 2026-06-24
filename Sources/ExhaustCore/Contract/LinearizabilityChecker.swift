/// Tests whether a concurrent execution's observed responses are consistent with some valid sequential ordering.
///
/// The checker enumerates valid interleavings that preserve per-lane command order. For each ordering, it replays the commands via the caller's closures, compares per-step responses via ``structurallyEqual(_:_:)``, and checks the oracle against the concurrent execution's final state. If any ordering produces matching responses and passes the oracle, the execution is linearizable.
///
/// The preemptive runner produces a fully overlapping history: every concurrent command overlaps every command on another lane, so the only ordering constraint is each lane's own command order. Enumerating the interleavings that preserve per-lane order therefore covers exactly the candidate orderings, which is why no cross-lane timestamps are recorded.
///
/// On failure, the checker reports the ``Witness``: the concurrent command whose observed response no ordering reproduces. This pins a response-level violation to a single command, the case the final-state diff cannot show, because the end state may coincidentally match a valid ordering even though no ordering yields the observed return value. When divergence is only in the final state (the oracle), there is no command witness and ``Witness`` is `nil`; that case is already visible in the expected-versus-actual state diff.
///
/// Both synchronous and asynchronous replay are supported. The interleaving search and response comparison are shared; only the replay-and-verify step differs.
package struct LinearizabilityChecker<Command>: @unchecked Sendable {
    /// The response from replaying a single command on a fresh sequential instance.
    package struct ReplayResponse {
        package let returnValue: Any?
        package let isSkipped: Bool

        package init(returnValue: Any?, isSkipped: Bool) {
            self.returnValue = returnValue
            self.isSkipped = isSkipped
        }
    }

    /// The concurrent command whose observed response no valid ordering reproduces, addressed by its position in ``laneObservations`` (`laneIndex` is the outer index, `commandIndex` the per-lane offset). The caller maps these coordinates back to a renderable command.
    package struct Witness: Sendable {
        package let laneIndex: Int
        package let commandIndex: Int
    }

    /// Result of a linearizability check.
    package enum Result {
        case linearizable
        case notLinearizable(witness: Witness?, failureDescription: String?)
    }

    package let laneObservations: [[ObservedResponse<Command>]]

    package init(laneObservations: [[ObservedResponse<Command>]]) {
        self.laneObservations = laneObservations
    }

    /// A command placed at a position in a candidate ordering, retaining its source coordinates so the witness can name it. Stored as an index pair rather than carrying a full ``Observation`` copy to keep the DFS working array (``SearchState/currentOrdering``) compact.
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
    ///   - replayCommand: Replays a single concurrent command on the sequential instance. Returns `nil` if the command threw a non-skip error.
    ///   - checkOracle: Checks whether the sequential instance's final state matches the concurrent execution's final state.
    ///   - failureDescription: Produces a human-readable description of the expected state on failure.
    package func check(
        replayPrefix: () -> Bool,
        replayCommand: (Command) -> ReplayResponse?,
        checkOracle: () -> Bool,
        failureDescription: () -> String?
    ) -> Result {
        let laneCount = laneObservations.count
        guard laneCount > 0 else {
            return .linearizable
        }

        let totalCommands = laneObservations.reduce(0) { $0 + $1.count }
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
        replayCommand: (Command) -> ReplayResponse?
    ) -> Bool {
        guard replayPrefix() else { return false }
        for index in 0 ..< depth {
            let placed = currentOrdering[index]
            guard replayCommand(laneObservations[placed.laneIndex][placed.commandIndex].command) != nil else { return false }
        }
        return true
    }

    private func searchIncrementally(
        totalCommands: Int,
        state: inout SearchState,
        replayPrefix: () -> Bool,
        replayCommand: (Command) -> ReplayResponse?,
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

        for laneIndex in 0 ..< laneObservations.count {
            let cursor = state.cursors[laneIndex]
            guard cursor < laneObservations[laneIndex].count else { continue }

            let observation = laneObservations[laneIndex][cursor]

            if childrenTried > 0 || depth == 0 {
                guard replayToDepth(depth, currentOrdering: state.currentOrdering, replayPrefix: replayPrefix, replayCommand: replayCommand) else {
                    continue
                }
            }
            childrenTried += 1

            let placed = Placed(laneIndex: laneIndex, commandIndex: cursor)

            guard let replay = replayCommand(observation.command) else {
                updateClosest(depth: depth, placed: placed, closestMatchDepth: &state.closestMatchDepth, closestPlaced: &state.closestPlaced)
                continue
            }

            if stepMismatches(observed: observation, replay: replay) {
                updateClosest(depth: depth, placed: placed, closestMatchDepth: &state.closestMatchDepth, closestPlaced: &state.closestPlaced)
                continue
            }

            if observation.outcome.isSkipped == false, responsesMatch(observed: observation, replay: replay) == false {
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
        replayCommand: (Command) async -> ReplayResponse?,
        checkOracle: () async -> Bool,
        failureDescription: () -> String?
    ) async -> Result {
        let laneCount = laneObservations.count
        guard laneCount > 0 else {
            return .linearizable
        }

        let totalCommands = laneObservations.reduce(0) { $0 + $1.count }
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
        replayCommand: (Command) async -> ReplayResponse?
    ) async -> Bool {
        guard await replayPrefix() else { return false }
        for index in 0 ..< depth {
            let placed = currentOrdering[index]
            guard await replayCommand(laneObservations[placed.laneIndex][placed.commandIndex].command) != nil else { return false }
        }
        return true
    }

    private func searchIncrementallyAsync(
        totalCommands: Int,
        state: inout SearchState,
        replayPrefix: () async -> Bool,
        replayCommand: (Command) async -> ReplayResponse?,
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

        for laneIndex in 0 ..< laneObservations.count {
            let cursor = state.cursors[laneIndex]
            guard cursor < laneObservations[laneIndex].count else { continue }

            let observation = laneObservations[laneIndex][cursor]

            if childrenTried > 0 || depth == 0 {
                guard await replayToDepthAsync(depth, currentOrdering: state.currentOrdering, replayPrefix: replayPrefix, replayCommand: replayCommand) else {
                    continue
                }
            }
            childrenTried += 1

            let placed = Placed(laneIndex: laneIndex, commandIndex: cursor)

            guard let replay = await replayCommand(observation.command) else {
                updateClosest(depth: depth, placed: placed, closestMatchDepth: &state.closestMatchDepth, closestPlaced: &state.closestPlaced)
                continue
            }

            if stepMismatches(observed: observation, replay: replay) {
                updateClosest(depth: depth, placed: placed, closestMatchDepth: &state.closestMatchDepth, closestPlaced: &state.closestPlaced)
                continue
            }

            if observation.outcome.isSkipped == false, responsesMatch(observed: observation, replay: replay) == false {
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

    private func stepMismatches(observed: ObservedResponse<Command>, replay: ReplayResponse) -> Bool {
        observed.outcome.isSkipped != replay.isSkipped
    }

    private func responsesMatch(observed: ObservedResponse<Command>, replay: ReplayResponse) -> Bool {
        switch (observed.outcome.returnValue, replay.returnValue) {
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
