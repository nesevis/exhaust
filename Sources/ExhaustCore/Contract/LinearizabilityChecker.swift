/// Tests whether a concurrent execution's observed responses are consistent with some valid sequential ordering.
///
/// The checker enumerates valid interleavings that preserve per-lane command order. For each ordering, it replays the commands via the caller's closures, compares per-step responses via ``structurallyEqual(_:_:)``, and checks the oracle against the concurrent execution's final state. If any ordering produces matching responses and passes the oracle, the execution is linearizable.
///
/// The checker runs post-lane-collapse, so the concurrent phase is typically two to four commands across two lanes (two to six valid orderings).
///
/// Both synchronous and asynchronous replay are supported. The interleaving search and response comparison are shared; only the replay-and-verify step differs.
package struct LinearizabilityChecker<Command> {
    /// One command's observed result during a concurrent execution, recorded per-lane.
    package struct Observation {
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

    /// Result of a linearizability check.
    package enum Result {
        case linearizable
        case notLinearizable(closestOrdering: [String], divergenceStep: Int)
    }

    package let laneObservations: [[Observation]]

    package init(laneObservations: [[Observation]]) {
        self.laneObservations = laneObservations
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
        var currentOrdering: [Observation] = []
        currentOrdering.reserveCapacity(totalCommands)

        var closestMatchDepth = -1
        var closestOrdering: [Observation] = []

        let verify: ([Observation]) -> Bool = { ordering in
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
        var currentOrdering: [Observation] = []
        currentOrdering.reserveCapacity(totalCommands)

        var closestMatchDepth = -1
        var closestOrdering: [Observation] = []

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
        currentOrdering: inout [Observation],
        totalCommands: Int,
        verify: ([Observation]) -> Bool
    ) -> Bool {
        if currentOrdering.count == totalCommands {
            return verify(currentOrdering)
        }

        for laneIndex in 0 ..< laneObservations.count {
            let cursor = cursors[laneIndex]
            guard cursor < laneObservations[laneIndex].count else { continue }

            let observation = laneObservations[laneIndex][cursor]
            cursors[laneIndex] += 1
            currentOrdering.append(observation)

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
        currentOrdering: inout [Observation],
        totalCommands: Int,
        closestMatchDepth: inout Int,
        closestOrdering: inout [Observation],
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
            currentOrdering.append(observation)

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
        _ ordering: [Observation],
        replayCommand: (Command) -> ReplayResponse?,
        checkOracle: () -> Bool,
        closestMatchDepth: inout Int,
        closestOrdering: inout [Observation]
    ) -> Bool {
        for (index, observed) in ordering.enumerated() {
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
        _ ordering: [Observation],
        replayCommand: (Command) async -> ReplayResponse?,
        checkOracle: () async -> Bool,
        closestMatchDepth: inout Int,
        closestOrdering: inout [Observation]
    ) async -> Bool {
        for (index, observed) in ordering.enumerated() {
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
        _ ordering: [Observation],
        matchDepth: Int,
        closestMatchDepth: inout Int,
        closestOrdering: inout [Observation]
    ) {
        if matchDepth > closestMatchDepth {
            closestMatchDepth = matchDepth
            closestOrdering = ordering
        }
    }

    private func makeResult(found: Bool, closestMatchDepth: Int, closestOrdering: [Observation]) -> Result {
        if found {
            return .linearizable
        }
        return .notLinearizable(
            closestOrdering: closestOrdering.map(\.commandDescription),
            divergenceStep: closestMatchDepth + 1
        )
    }
}
