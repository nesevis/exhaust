// MARK: - Academic Background

//
// Linearizability is the correctness condition of Herlihy and Wing, "Linearizability: A Correctness Condition for Concurrent Objects" (ACM TOPLAS, 1990). A concurrent history is linearizable when its operations can be put in some one-at-a-time order that produces the same results (their condition L1) and respects the real-time order of any two operations that did not overlap (their condition L2).
//
// The interleaving search follows the testing approach of Lowe, "Testing for Linearizability" (Concurrency and Computation: Practice and Experience, 2017), which records a concurrent history and searches for a sequential order that reproduces it. That work builds on the earlier Wing and Gong algorithm, whose replay-and-compare loop this checker mirrors.
//
// The preemptive runner produces a restricted history: every concurrent command overlaps every command on another lane, so the only real-time constraint is each lane's own command order. Enumerating the interleavings that keep per-lane order therefore covers exactly the candidate linearizations, which is why no cross-lane timestamps are recorded.

/// Tests whether a concurrent execution's observed responses are consistent with some valid sequential ordering.
///
/// The checker enumerates valid interleavings that preserve per-lane command order. For each ordering, it replays the commands via the caller's closures, compares per-step responses via ``structurallyEqual(_:_:)``, and checks the oracle against the concurrent execution's final state. If any ordering produces matching responses and passes the oracle, the execution is linearizable.
///
/// On failure, the checker reports the ``Witness``: the concurrent command whose observed response no ordering reproduces. This pins a response-level violation to a single command, the case the final-state diff cannot show, because the end state may coincidentally match a valid ordering even though no ordering yields the observed return value. When divergence is only in the final state (the oracle), there is no command witness and ``Witness`` is `nil`; that case is already visible in the expected-versus-actual state diff.
///
/// Both synchronous and asynchronous replay are supported. The interleaving search and response comparison are shared; only the replay-and-verify step differs.
package struct LinearizabilityChecker<Command>: @unchecked Sendable {
    /// One command's observed result during a concurrent execution, recorded per-lane.
    package struct Observation: @unchecked Sendable {
        package let command: Command
        package let commandDescription: String
        package let returnValue: Any?
        package let isSkipped: Bool

        package init(
            command: Command,
            commandDescription: String,
            returnValue: Any?,
            isSkipped: Bool
        ) {
            self.command = command
            self.commandDescription = commandDescription
            self.returnValue = returnValue
            self.isSkipped = isSkipped
        }
    }

    /// The response from replaying a single command on a fresh sequential instance.
    package struct ReplayResponse {
        package let commandDescription: String
        package let returnValue: Any?
        package let isSkipped: Bool

        package init(commandDescription: String, returnValue: Any?, isSkipped: Bool) {
            self.commandDescription = commandDescription
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
        case notLinearizable(witness: Witness?)
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

    /// Checks linearizability using synchronous replay closures.
    ///
    /// - Parameters:
    ///   - prefix: The sequential prefix commands to replay before each candidate ordering.
    ///   - replayPrefix: Replays all prefix commands on a fresh sequential instance. Returns `false` if any prefix command fails.
    ///   - replayCommand: Replays a single concurrent command on the sequential instance. Returns `nil` if the command threw a non-skip error.
    ///   - checkOracle: Checks whether the sequential instance's final state matches the concurrent execution's final state.
    package func check(
        prefix: [Command],
        replayPrefix: ([Command]) -> Bool,
        replayCommand: (Command) -> ReplayResponse?,
        checkOracle: () -> Bool
    ) -> Result {
        let laneCount = laneObservations.count
        guard laneCount > 0 else {
            return .linearizable
        }

        var cursors = Array(repeating: 0, count: laneCount)
        let totalCommands = laneObservations.reduce(0) { $0 + $1.count }
        var currentOrdering: [Placed] = []
        currentOrdering.reserveCapacity(totalCommands)

        var closestMatchDepth = -1
        var closestOrdering: [Placed] = []

        let verify: ([Placed]) -> Bool = { ordering in
            guard replayPrefix(prefix) else { return false }
            return verifyOrdering(
                ordering,
                replayCommand: replayCommand,
                checkOracle: checkOracle,
                closestMatchDepth: &closestMatchDepth,
                closestOrdering: &closestOrdering
            )
        }

        let found = searchOrderings(
            cursors: &cursors,
            currentOrdering: &currentOrdering,
            totalCommands: totalCommands,
            verify: verify
        )

        return makeResult(found: found, closestMatchDepth: closestMatchDepth, closestOrdering: closestOrdering)
    }

    // MARK: - Asynchronous

    /// Checks linearizability using asynchronous replay closures.
    ///
    /// Same algorithm as ``check(prefix:replayPrefix:replayCommand:checkOracle:)`` but awaits each replay step, avoiding thread blocking in async contract runners.
    package func checkAsync(
        prefix: [Command],
        replayPrefix: ([Command]) async -> Bool,
        replayCommand: (Command) async -> ReplayResponse?,
        checkOracle: () async -> Bool
    ) async -> Result {
        let laneCount = laneObservations.count
        guard laneCount > 0 else {
            return .linearizable
        }

        var cursors = Array(repeating: 0, count: laneCount)
        let totalCommands = laneObservations.reduce(0) { $0 + $1.count }
        var currentOrdering: [Placed] = []
        currentOrdering.reserveCapacity(totalCommands)

        var closestMatchDepth = -1
        var closestOrdering: [Placed] = []

        let found = await searchOrderingsAsync(
            prefix: prefix,
            cursors: &cursors,
            currentOrdering: &currentOrdering,
            totalCommands: totalCommands,
            closestMatchDepth: &closestMatchDepth,
            closestOrdering: &closestOrdering,
            replayPrefix: replayPrefix,
            replayCommand: replayCommand,
            checkOracle: checkOracle
        )

        return makeResult(found: found, closestMatchDepth: closestMatchDepth, closestOrdering: closestOrdering)
    }

    // MARK: - Shared Search

    /// Depth-first search over valid interleavings. At each step, tries advancing each lane's cursor in turn. Calls `verify` for each complete ordering.
    private func searchOrderings(
        cursors: inout [Int],
        currentOrdering: inout [Placed],
        totalCommands: Int,
        verify: ([Placed]) -> Bool
    ) -> Bool {
        if currentOrdering.count == totalCommands {
            return verify(currentOrdering)
        }

        for laneIndex in 0 ..< laneObservations.count {
            let cursor = cursors[laneIndex]
            guard cursor < laneObservations[laneIndex].count else { continue }

            let observation = laneObservations[laneIndex][cursor]
            cursors[laneIndex] += 1
            currentOrdering.append(Placed(laneIndex: laneIndex, commandIndex: cursor, observation: observation))

            let found = searchOrderings(
                cursors: &cursors,
                currentOrdering: &currentOrdering,
                totalCommands: totalCommands,
                verify: verify
            )
            if found { return true }

            currentOrdering.removeLast()
            cursors[laneIndex] -= 1
        }

        return false
    }

    /// Async variant of ``searchOrderings(cursors:currentOrdering:totalCommands:verify:)``.
    private func searchOrderingsAsync(
        prefix: [Command],
        cursors: inout [Int],
        currentOrdering: inout [Placed],
        totalCommands: Int,
        closestMatchDepth: inout Int,
        closestOrdering: inout [Placed],
        replayPrefix: ([Command]) async -> Bool,
        replayCommand: (Command) async -> ReplayResponse?,
        checkOracle: () async -> Bool
    ) async -> Bool {
        if currentOrdering.count == totalCommands {
            guard await replayPrefix(prefix) else { return false }
            return await verifyOrderingAsync(
                currentOrdering,
                replayCommand: replayCommand,
                checkOracle: checkOracle,
                closestMatchDepth: &closestMatchDepth,
                closestOrdering: &closestOrdering
            )
        }

        for laneIndex in 0 ..< laneObservations.count {
            let cursor = cursors[laneIndex]
            guard cursor < laneObservations[laneIndex].count else { continue }

            let observation = laneObservations[laneIndex][cursor]
            cursors[laneIndex] += 1
            currentOrdering.append(Placed(laneIndex: laneIndex, commandIndex: cursor, observation: observation))

            let found = await searchOrderingsAsync(
                prefix: prefix,
                cursors: &cursors,
                currentOrdering: &currentOrdering,
                totalCommands: totalCommands,
                closestMatchDepth: &closestMatchDepth,
                closestOrdering: &closestOrdering,
                replayPrefix: replayPrefix,
                replayCommand: replayCommand,
                checkOracle: checkOracle
            )
            if found { return true }

            currentOrdering.removeLast()
            cursors[laneIndex] -= 1
        }

        return false
    }

    // MARK: - Verify Ordering

    /// Replays a candidate ordering against the sequential instance (already prefix-replayed), comparing responses and checking the oracle.
    private func verifyOrdering(
        _ ordering: [Placed],
        replayCommand: (Command) -> ReplayResponse?,
        checkOracle: () -> Bool,
        closestMatchDepth: inout Int,
        closestOrdering: inout [Placed]
    ) -> Bool {
        for (index, placed) in ordering.enumerated() {
            let observed = placed.observation
            guard let replay = replayCommand(observed.command) else {
                updateClosest(ordering, matchDepth: index, closestMatchDepth: &closestMatchDepth, closestOrdering: &closestOrdering)
                return false
            }

            if stepMismatches(observed: observed, replay: replay) {
                updateClosest(ordering, matchDepth: index, closestMatchDepth: &closestMatchDepth, closestOrdering: &closestOrdering)
                return false
            }

            if observed.isSkipped {
                continue
            }

            if responsesMatch(observed: observed, replay: replay) == false {
                updateClosest(ordering, matchDepth: index, closestMatchDepth: &closestMatchDepth, closestOrdering: &closestOrdering)
                return false
            }
        }

        let oraclePassed = checkOracle()
        if oraclePassed == false {
            updateClosest(ordering, matchDepth: ordering.count, closestMatchDepth: &closestMatchDepth, closestOrdering: &closestOrdering)
        }
        return oraclePassed
    }

    /// Async variant of ``verifyOrdering(_:replayCommand:checkOracle:closestMatchDepth:closestOrdering:)``.
    private func verifyOrderingAsync(
        _ ordering: [Placed],
        replayCommand: (Command) async -> ReplayResponse?,
        checkOracle: () async -> Bool,
        closestMatchDepth: inout Int,
        closestOrdering: inout [Placed]
    ) async -> Bool {
        for (index, placed) in ordering.enumerated() {
            let observed = placed.observation
            guard let replay = await replayCommand(observed.command) else {
                updateClosest(ordering, matchDepth: index, closestMatchDepth: &closestMatchDepth, closestOrdering: &closestOrdering)
                return false
            }

            if stepMismatches(observed: observed, replay: replay) {
                updateClosest(ordering, matchDepth: index, closestMatchDepth: &closestMatchDepth, closestOrdering: &closestOrdering)
                return false
            }

            if observed.isSkipped {
                continue
            }

            if responsesMatch(observed: observed, replay: replay) == false {
                updateClosest(ordering, matchDepth: index, closestMatchDepth: &closestMatchDepth, closestOrdering: &closestOrdering)
                return false
            }
        }

        let oraclePassed = await checkOracle()
        if oraclePassed == false {
            updateClosest(ordering, matchDepth: ordering.count, closestMatchDepth: &closestMatchDepth, closestOrdering: &closestOrdering)
        }
        return oraclePassed
    }

    // MARK: - Shared Helpers

    private func stepMismatches(observed: Observation, replay: ReplayResponse) -> Bool {
        observed.isSkipped != replay.isSkipped
    }

    private func responsesMatch(observed: Observation, replay: ReplayResponse) -> Bool {
        // The same command is replayed, so for macro-generated specs (whose description derives from the command alone) the descriptions always match and this is a no-op. It guards a hand-written `run` whose description varies with state.
        if observed.commandDescription != replay.commandDescription {
            return false
        }

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
    private func makeResult(found: Bool, closestMatchDepth: Int, closestOrdering: [Placed]) -> Result {
        guard found == false else {
            return .linearizable
        }
        guard closestMatchDepth >= 0, closestMatchDepth < closestOrdering.count else {
            return .notLinearizable(witness: nil)
        }
        let placed = closestOrdering[closestMatchDepth]
        return .notLinearizable(witness: Witness(laneIndex: placed.laneIndex, commandIndex: placed.commandIndex))
    }
}
