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
    /// One command's observed result during a concurrent execution, recorded per-lane.
    package struct Observation: @unchecked Sendable {
        package let command: Command
        package let returnValue: Any?
        package let isSkipped: Bool

        package init(
            command: Command,
            returnValue: Any?,
            isSkipped: Bool
        ) {
            self.command = command
            self.returnValue = returnValue
            self.isSkipped = isSkipped
        }
    }

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

    package let laneObservations: [[Observation]]

    package init(laneObservations: [[Observation]]) {
        self.laneObservations = laneObservations
    }

    /// A command placed at a position in a candidate ordering, retaining its source coordinates so the witness can name it.
    private struct Placed {
        let laneIndex: Int
        let commandIndex: Int
        let observation: Observation
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

        return makeResult(found: found, closestMatchDepth: state.closestMatchDepth, closestOrdering: state.closestOrdering, failureDescription: failureDescription)
    }

    // MARK: - Search State

    private struct SearchState {
        var cursors: [Int]
        var currentOrdering: [Placed]
        var closestMatchDepth: Int = -1
        var closestOrdering: [Placed] = []

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
            guard replayCommand(currentOrdering[index].observation.command) != nil else { return false }
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
                updateClosest(state.currentOrdering, matchDepth: depth, closestMatchDepth: &state.closestMatchDepth, closestOrdering: &state.closestOrdering)
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

            let placed = Placed(laneIndex: laneIndex, commandIndex: cursor, observation: observation)

            guard let replay = replayCommand(observation.command) else {
                state.currentOrdering.append(placed)
                updateClosest(state.currentOrdering, matchDepth: depth, closestMatchDepth: &state.closestMatchDepth, closestOrdering: &state.closestOrdering)
                state.currentOrdering.removeLast()
                continue
            }

            if stepMismatches(observed: observation, replay: replay) {
                state.currentOrdering.append(placed)
                updateClosest(state.currentOrdering, matchDepth: depth, closestMatchDepth: &state.closestMatchDepth, closestOrdering: &state.closestOrdering)
                state.currentOrdering.removeLast()
                continue
            }

            if observation.isSkipped == false, responsesMatch(observed: observation, replay: replay) == false {
                state.currentOrdering.append(placed)
                updateClosest(state.currentOrdering, matchDepth: depth, closestMatchDepth: &state.closestMatchDepth, closestOrdering: &state.closestOrdering)
                state.currentOrdering.removeLast()
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

        return makeResult(found: found, closestMatchDepth: state.closestMatchDepth, closestOrdering: state.closestOrdering, failureDescription: failureDescription)
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
            guard await replayCommand(currentOrdering[index].observation.command) != nil else { return false }
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
                updateClosest(state.currentOrdering, matchDepth: depth, closestMatchDepth: &state.closestMatchDepth, closestOrdering: &state.closestOrdering)
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

            let placed = Placed(laneIndex: laneIndex, commandIndex: cursor, observation: observation)

            guard let replay = await replayCommand(observation.command) else {
                state.currentOrdering.append(placed)
                updateClosest(state.currentOrdering, matchDepth: depth, closestMatchDepth: &state.closestMatchDepth, closestOrdering: &state.closestOrdering)
                state.currentOrdering.removeLast()
                continue
            }

            if stepMismatches(observed: observation, replay: replay) {
                state.currentOrdering.append(placed)
                updateClosest(state.currentOrdering, matchDepth: depth, closestMatchDepth: &state.closestMatchDepth, closestOrdering: &state.closestOrdering)
                state.currentOrdering.removeLast()
                continue
            }

            if observation.isSkipped == false, responsesMatch(observed: observation, replay: replay) == false {
                state.currentOrdering.append(placed)
                updateClosest(state.currentOrdering, matchDepth: depth, closestMatchDepth: &state.closestMatchDepth, closestOrdering: &state.closestOrdering)
                state.currentOrdering.removeLast()
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

    private func stepMismatches(observed: Observation, replay: ReplayResponse) -> Bool {
        observed.isSkipped != replay.isSkipped
    }

    private func responsesMatch(observed: Observation, replay: ReplayResponse) -> Bool {
        switch (observed.returnValue, replay.returnValue) {
            case (nil, nil):
                return true
            case let (observedValue?, replayValue?):
                return structurallyEqual(observedValue, replayValue)
            default:
                return false
        }
    }

    private func updateClosest(
        _ ordering: [Placed],
        matchDepth: Int,
        closestMatchDepth: inout Int,
        closestOrdering: inout [Placed]
    ) {
        if matchDepth > closestMatchDepth {
            closestMatchDepth = matchDepth
            closestOrdering = ordering
        }
    }

    /// Builds the verdict. The witness is the command at the deepest divergence point reached across all orderings; when divergence is only at the oracle (`closestMatchDepth == totalCommands`, so the index is out of bounds) there is no command witness.
    private func makeResult(found: Bool, closestMatchDepth: Int, closestOrdering: [Placed], failureDescription: () -> String?) -> Result {
        guard found == false else {
            return .linearizable
        }
        guard closestMatchDepth >= 0, closestMatchDepth < closestOrdering.count else {
            return .notLinearizable(witness: nil, failureDescription: failureDescription())
        }
        let placed = closestOrdering[closestMatchDepth]
        return .notLinearizable(witness: Witness(laneIndex: placed.laneIndex, commandIndex: placed.commandIndex), failureDescription: failureDescription())
    }
}
