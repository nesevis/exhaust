/// Cross-run cache for the linearizability checker's prefix memoization.
///
/// Stores 64-bit Zobrist hashes of (observation set, prefix, cursor state) triples whose subtrees have been fully explored with no valid completion. Caller-owned: the reduction loop creates one cache at the start of a pass and feeds it to every ``LinearizabilityChecker/check(prefix:replayPrefix:replayCommand:checkOracle:observationHashes:prefixCache:)`` call within that pass.
package struct LinearizabilityPrefixCache: Sendable {
    package private(set) var entries: Set<UInt64> = []

    package init() {}

    package func contains(_ key: UInt64) -> Bool {
        entries.contains(key)
    }

    package mutating func insert(_ key: UInt64) {
        entries.insert(key)
    }
}

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

    /// Checks linearizability without caching.
    package func check(
        prefix: [Command],
        replayPrefix: ([Command]) -> Bool,
        replayCommand: (Command) -> ReplayResponse?,
        checkOracle: () -> Bool
    ) -> Result {
        var noCache: LinearizabilityPrefixCache?
        return check(
            prefix: prefix,
            replayPrefix: replayPrefix,
            replayCommand: replayCommand,
            checkOracle: checkOracle,
            observationHashes: nil,
            prefixCache: &noCache
        )
    }

    /// Checks linearizability using synchronous replay closures with incremental verification and prefix caching.
    ///
    /// Folds verification into the DFS: each placed command is replayed immediately and the subtree is pruned on mismatch. When `observationHashes` and `prefixCache` are both non-nil, exhausted subtrees are memoized via Zobrist-hashed (observation set, prefix, cursor state) keys, and cache hits prune without replay. Aggregate hit/miss counts are logged under the `linearizability` category when logging is enabled.
    ///
    /// - Parameters:
    ///   - prefix: The sequential prefix commands to replay before each candidate ordering.
    ///   - replayPrefix: Replays all prefix commands on a fresh sequential instance. Returns `false` if any prefix command fails.
    ///   - replayCommand: Replays a single concurrent command on the sequential instance. Returns `nil` if the command threw a non-skip error.
    ///   - checkOracle: Checks whether the sequential instance's final state matches the concurrent execution's final state.
    ///   - observationHashes: Per-observation fingerprints (same shape as ``laneObservations``), precomputed from ChoiceSequence segments and response outcomes. `nil` disables caching.
    ///   - prefixCache: Cross-run cache of exhausted subtrees. `nil` disables caching.
    package func check(
        prefix: [Command],
        replayPrefix: ([Command]) -> Bool,
        replayCommand: (Command) -> ReplayResponse?,
        checkOracle: () -> Bool,
        observationHashes: [[UInt64]]?,
        prefixCache: inout LinearizabilityPrefixCache?
    ) -> Result {
        let laneCount = laneObservations.count
        guard laneCount > 0 else {
            return .linearizable
        }

        let totalCommands = laneObservations.reduce(0) { $0 + $1.count }
        let cachingEnabled = observationHashes != nil && prefixCache != nil

        // Observation set hash: constant for this check, distinguishes checks with different observations.
        var observationSetHash: UInt64 = 0
        if let observationHashes {
            for (laneIndex, lane) in observationHashes.enumerated() {
                for (commandIndex, hash) in lane.enumerated() {
                    observationSetHash ^= mixPositionDependent(hash, position: laneIndex &* 256 &+ commandIndex)
                }
            }
        }

        var cursors = Array(repeating: 0, count: laneCount)
        var currentOrdering: [Placed] = []
        currentOrdering.reserveCapacity(totalCommands)
        var closestMatchDepth = -1
        var closestOrdering: [Placed] = []

        var prefixHash: UInt64 = 0
        var cursorHash: UInt64 = 0
        var cacheHits = 0
        var cacheMisses = 0
        var nodesVisited = 0
        var nodesPruned = 0

        let found = searchIncrementally(
            prefix: prefix,
            cursors: &cursors,
            currentOrdering: &currentOrdering,
            totalCommands: totalCommands,
            closestMatchDepth: &closestMatchDepth,
            closestOrdering: &closestOrdering,
            replayPrefix: replayPrefix,
            replayCommand: replayCommand,
            checkOracle: checkOracle,
            observationHashes: observationHashes,
            prefixCache: &prefixCache,
            cachingEnabled: cachingEnabled,
            observationSetHash: observationSetHash,
            prefixHash: &prefixHash,
            cursorHash: &cursorHash,
            cacheHits: &cacheHits,
            cacheMisses: &cacheMisses,
            nodesVisited: &nodesVisited,
            nodesPruned: &nodesPruned
        )

        if cacheHits + cacheMisses > 0 {
            ExhaustLog.debug(
                category: .propertyTest,
                event: "linearizability_cache",
                metadata: [
                    "commands": "\(totalCommands)",
                    "hits": "\(cacheHits)",
                    "misses": "\(cacheMisses)",
                    "nodes_visited": "\(nodesVisited)",
                    "nodes_pruned": "\(nodesPruned)",
                    "cache_entries": "\(prefixCache?.entries.count ?? 0)",
                    "result": found ? "linearizable" : "not_linearizable",
                ]
            )
        }

        return makeResult(found: found, closestMatchDepth: closestMatchDepth, closestOrdering: closestOrdering)
    }

    // MARK: - Incremental Search

    /// Replays the sequential prefix and the first `depth` commands of `currentOrdering` to restore the spec to the state at `depth`. Every sibling at the same depth needs the spec in the parent's state before its own command is applied.
    private func replayToDepth(
        _ depth: Int,
        prefix: [Command],
        currentOrdering: [Placed],
        replayPrefix: ([Command]) -> Bool,
        replayCommand: (Command) -> ReplayResponse?
    ) -> Bool {
        guard replayPrefix(prefix) else { return false }
        for index in 0 ..< depth {
            guard replayCommand(currentOrdering[index].observation.command) != nil else { return false }
        }
        return true
    }

    /// Depth-first search with incremental verification. Each placed command is replayed immediately; mismatches prune the subtree. Cache lookups and insertions happen when `cachingEnabled` is true.
    private func searchIncrementally(
        prefix: [Command],
        cursors: inout [Int],
        currentOrdering: inout [Placed],
        totalCommands: Int,
        closestMatchDepth: inout Int,
        closestOrdering: inout [Placed],
        replayPrefix: ([Command]) -> Bool,
        replayCommand: (Command) -> ReplayResponse?,
        checkOracle: () -> Bool,
        observationHashes: [[UInt64]]?,
        prefixCache: inout LinearizabilityPrefixCache?,
        cachingEnabled: Bool,
        observationSetHash: UInt64,
        prefixHash: inout UInt64,
        cursorHash: inout UInt64,
        cacheHits: inout Int,
        cacheMisses: inout Int,
        nodesVisited: inout Int,
        nodesPruned: inout Int
    ) -> Bool {
        let depth = currentOrdering.count
        nodesVisited += 1

        if depth == totalCommands {
            // All commands verified incrementally. Ensure spec state is valid (handles totalCommands == 0 where no incremental replays occurred), then check the oracle.
            if depth == 0 {
                guard replayPrefix(prefix) else { return false }
            }
            let oraclePassed = checkOracle()
            if oraclePassed == false {
                updateClosest(currentOrdering, matchDepth: depth, closestMatchDepth: &closestMatchDepth, closestOrdering: &closestOrdering)
            }
            return oraclePassed
        }

        // Cache lookup: if this (observation set, prefix, cursor) was already exhausted, prune.
        if cachingEnabled {
            let cacheKey = mixCacheKey(observationSetHash, prefixHash, cursorHash)
            if prefixCache?.contains(cacheKey) == true {
                cacheHits += 1
                nodesPruned += 1
                return false
            }
            cacheMisses += 1
        }

        var childrenTried = 0

        for laneIndex in 0 ..< laneObservations.count {
            let cursor = cursors[laneIndex]
            guard cursor < laneObservations[laneIndex].count else { continue }

            let observation = laneObservations[laneIndex][cursor]

            // Restore spec state to this depth. The first child at each depth needs replay too — the spec has no guaranteed state at entry.
            if childrenTried > 0 || depth == 0 {
                guard replayToDepth(depth, prefix: prefix, currentOrdering: currentOrdering, replayPrefix: replayPrefix, replayCommand: replayCommand) else {
                    continue
                }
            }
            childrenTried += 1

            // Incremental check: replay this one command and compare.
            let placed = Placed(laneIndex: laneIndex, commandIndex: cursor, observation: observation)

            guard let replay = replayCommand(observation.command) else {
                currentOrdering.append(placed)
                updateClosest(currentOrdering, matchDepth: depth, closestMatchDepth: &closestMatchDepth, closestOrdering: &closestOrdering)
                currentOrdering.removeLast()
                nodesPruned += 1
                continue
            }

            if stepMismatches(observed: observation, replay: replay) {
                currentOrdering.append(placed)
                updateClosest(currentOrdering, matchDepth: depth, closestMatchDepth: &closestMatchDepth, closestOrdering: &closestOrdering)
                currentOrdering.removeLast()
                nodesPruned += 1
                continue
            }

            if observation.isSkipped == false, responsesMatch(observed: observation, replay: replay) == false {
                currentOrdering.append(placed)
                updateClosest(currentOrdering, matchDepth: depth, closestMatchDepth: &closestMatchDepth, closestOrdering: &closestOrdering)
                currentOrdering.removeLast()
                nodesPruned += 1
                continue
            }

            // Match at this depth — descend.
            let observationHash = observationHashes?[laneIndex][cursor] ?? 0
            let prefixContribution = mixPositionDependent(observationHash, position: depth)
            let oldCursorContribution = mixPositionDependent(UInt64(cursor), position: laneIndex)
            let newCursorContribution = mixPositionDependent(UInt64(cursor &+ 1), position: laneIndex)

            prefixHash ^= prefixContribution
            cursorHash ^= oldCursorContribution ^ newCursorContribution
            cursors[laneIndex] += 1
            currentOrdering.append(placed)

            let found = searchIncrementally(
                prefix: prefix,
                cursors: &cursors,
                currentOrdering: &currentOrdering,
                totalCommands: totalCommands,
                closestMatchDepth: &closestMatchDepth,
                closestOrdering: &closestOrdering,
                replayPrefix: replayPrefix,
                replayCommand: replayCommand,
                checkOracle: checkOracle,
                observationHashes: observationHashes,
                prefixCache: &prefixCache,
                cachingEnabled: cachingEnabled,
                observationSetHash: observationSetHash,
                prefixHash: &prefixHash,
                cursorHash: &cursorHash,
                cacheHits: &cacheHits,
                cacheMisses: &cacheMisses,
                nodesVisited: &nodesVisited,
                nodesPruned: &nodesPruned
            )

            currentOrdering.removeLast()
            cursors[laneIndex] -= 1
            prefixHash ^= prefixContribution
            cursorHash ^= oldCursorContribution ^ newCursorContribution

            if found { return true }
        }

        // All children exhausted with no valid completion — insert into cache.
        if cachingEnabled {
            let cacheKey = mixCacheKey(observationSetHash, prefixHash, cursorHash)
            prefixCache?.insert(cacheKey)
        }

        return false
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

// MARK: - Zobrist Mixing for Prefix Cache

/// Position-dependent hash mixing using splitmix64, matching ``ZobristHash/contribution(at:_:)``.
private func mixPositionDependent(_ value: UInt64, position: Int) -> UInt64 {
    var bits = value ^ (UInt64(position) &* 0x9E37_79B9_7F4A_7C15)
    bits = (bits ^ (bits >> 30)) &* 0xBF58_476D_1CE4_E5B9
    bits = (bits ^ (bits >> 27)) &* 0x94D0_49BB_1331_11EB
    bits ^= bits >> 31
    return bits
}

/// Combines the three cache key components into a single 64-bit key.
private func mixCacheKey(_ observationSetHash: UInt64, _ prefixHash: UInt64, _ cursorHash: UInt64) -> UInt64 {
    var combined = observationSetHash
    combined ^= prefixHash &* 0x9E37_79B9_7F4A_7C15
    combined ^= cursorHash &* 0x517C_C1B7_2722_0A95
    var bits = combined
    bits = (bits ^ (bits >> 30)) &* 0xBF58_476D_1CE4_E5B9
    bits = (bits ^ (bits >> 27)) &* 0x94D0_49BB_1331_11EB
    bits ^= bits >> 31
    return bits
}
