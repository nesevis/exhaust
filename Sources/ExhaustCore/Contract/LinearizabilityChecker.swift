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
        replayPrefix: () -> Bool,
        replayCommand: (Command) -> ReplayResponse?,
        checkOracle: () -> Bool
    ) -> Result {
        var noCache: LinearizabilityPrefixCache?
        return check(
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
    ///   - replayPrefix: Replays all prefix commands on a fresh sequential instance. Returns `false` if any prefix command fails. The closure captures its own prefix data.
    ///   - replayCommand: Replays a single concurrent command on the sequential instance. Returns `nil` if the command threw a non-skip error.
    ///   - checkOracle: Checks whether the sequential instance's final state matches the concurrent execution's final state.
    ///   - observationHashes: Per-observation fingerprints (same shape as ``laneObservations``), precomputed from ChoiceSequence segments and response outcomes. `nil` disables caching.
    ///   - prefixCache: Cross-run cache of exhausted subtrees. `nil` disables caching.
    package func check(
        replayPrefix: () -> Bool,
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
        let observationSetHash = computeObservationSetHash(observationHashes)

        var state = SearchState(laneCount: laneCount, totalCommands: totalCommands, prefixCache: prefixCache)

        let found = searchIncrementally(
            totalCommands: totalCommands,
            observationHashes: observationHashes,
            cachingEnabled: cachingEnabled,
            observationSetHash: observationSetHash,
            state: &state,
            replayPrefix: replayPrefix,
            replayCommand: replayCommand,
            checkOracle: checkOracle
        )

        prefixCache = state.prefixCache
        logCacheStats(state: state, totalCommands: totalCommands, found: found)
        return makeResult(found: found, closestMatchDepth: state.closestMatchDepth, closestOrdering: state.closestOrdering)
    }

    // MARK: - Search State

    private struct SearchState {
        var cursors: [Int]
        var currentOrdering: [Placed]
        var closestMatchDepth: Int = -1
        var closestOrdering: [Placed] = []
        var prefixHash: UInt64 = 0
        var cursorHash: UInt64 = 0
        var prefixCache: LinearizabilityPrefixCache?
        var cacheHits: Int = 0
        var cacheMisses: Int = 0
        var nodesVisited: Int = 0
        var nodesPruned: Int = 0

        init(laneCount: Int, totalCommands: Int, prefixCache: LinearizabilityPrefixCache?) {
            cursors = Array(repeating: 0, count: laneCount)
            currentOrdering = []
            currentOrdering.reserveCapacity(totalCommands)
            self.prefixCache = prefixCache
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
        observationHashes: [[UInt64]]?,
        cachingEnabled: Bool,
        observationSetHash: UInt64,
        state: inout SearchState,
        replayPrefix: () -> Bool,
        replayCommand: (Command) -> ReplayResponse?,
        checkOracle: () -> Bool
    ) -> Bool {
        let depth = state.currentOrdering.count
        state.nodesVisited += 1

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

        if cachingEnabled {
            let cacheKey = mixCacheKey(observationSetHash, state.prefixHash, state.cursorHash)
            if state.prefixCache?.contains(cacheKey) == true {
                state.cacheHits += 1
                state.nodesPruned += 1
                return false
            }
            state.cacheMisses += 1
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
                state.nodesPruned += 1
                continue
            }

            if stepMismatches(observed: observation, replay: replay) {
                state.currentOrdering.append(placed)
                updateClosest(state.currentOrdering, matchDepth: depth, closestMatchDepth: &state.closestMatchDepth, closestOrdering: &state.closestOrdering)
                state.currentOrdering.removeLast()
                state.nodesPruned += 1
                continue
            }

            if observation.isSkipped == false, responsesMatch(observed: observation, replay: replay) == false {
                state.currentOrdering.append(placed)
                updateClosest(state.currentOrdering, matchDepth: depth, closestMatchDepth: &state.closestMatchDepth, closestOrdering: &state.closestOrdering)
                state.currentOrdering.removeLast()
                state.nodesPruned += 1
                continue
            }

            let observationHash = observationHashes?[laneIndex][cursor] ?? 0
            let prefixContribution = ZobristHash.mix(observationHash, at: depth)
            let oldCursorContribution = ZobristHash.mix(UInt64(cursor), at: laneIndex)
            let newCursorContribution = ZobristHash.mix(UInt64(cursor &+ 1), at: laneIndex)

            state.prefixHash ^= prefixContribution
            state.cursorHash ^= oldCursorContribution ^ newCursorContribution
            state.cursors[laneIndex] += 1
            state.currentOrdering.append(placed)

            let found = searchIncrementally(
                totalCommands: totalCommands,
                observationHashes: observationHashes,
                cachingEnabled: cachingEnabled,
                observationSetHash: observationSetHash,
                state: &state,
                replayPrefix: replayPrefix,
                replayCommand: replayCommand,
                checkOracle: checkOracle
            )

            state.currentOrdering.removeLast()
            state.cursors[laneIndex] -= 1
            state.prefixHash ^= prefixContribution
            state.cursorHash ^= oldCursorContribution ^ newCursorContribution

            if found { return true }
        }

        if cachingEnabled {
            let cacheKey = mixCacheKey(observationSetHash, state.prefixHash, state.cursorHash)
            state.prefixCache?.insert(cacheKey)
        }

        return false
    }

    // MARK: - Asynchronous

    /// Checks linearizability using asynchronous replay closures, without caching.
    package func checkAsync(
        replayPrefix: () async -> Bool,
        replayCommand: (Command) async -> ReplayResponse?,
        checkOracle: () async -> Bool
    ) async -> Result {
        var noCache: LinearizabilityPrefixCache?
        return await checkAsync(
            replayPrefix: replayPrefix,
            replayCommand: replayCommand,
            checkOracle: checkOracle,
            observationHashes: nil,
            prefixCache: &noCache
        )
    }

    /// Checks linearizability using asynchronous replay closures with incremental verification and prefix caching.
    ///
    /// Async equivalent of ``check(replayPrefix:replayCommand:checkOracle:observationHashes:prefixCache:)``. Folds verification into the DFS with pruning on mismatch and Zobrist-hashed cache lookups.
    package func checkAsync(
        replayPrefix: () async -> Bool,
        replayCommand: (Command) async -> ReplayResponse?,
        checkOracle: () async -> Bool,
        observationHashes: [[UInt64]]?,
        prefixCache: inout LinearizabilityPrefixCache?
    ) async -> Result {
        let laneCount = laneObservations.count
        guard laneCount > 0 else {
            return .linearizable
        }

        let totalCommands = laneObservations.reduce(0) { $0 + $1.count }
        let cachingEnabled = observationHashes != nil && prefixCache != nil
        let observationSetHash = computeObservationSetHash(observationHashes)

        var state = SearchState(laneCount: laneCount, totalCommands: totalCommands, prefixCache: prefixCache)

        let found = await searchIncrementallyAsync(
            totalCommands: totalCommands,
            observationHashes: observationHashes,
            cachingEnabled: cachingEnabled,
            observationSetHash: observationSetHash,
            state: &state,
            replayPrefix: replayPrefix,
            replayCommand: replayCommand,
            checkOracle: checkOracle
        )

        prefixCache = state.prefixCache
        logCacheStats(state: state, totalCommands: totalCommands, found: found)
        return makeResult(found: found, closestMatchDepth: state.closestMatchDepth, closestOrdering: state.closestOrdering)
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
        observationHashes: [[UInt64]]?,
        cachingEnabled: Bool,
        observationSetHash: UInt64,
        state: inout SearchState,
        replayPrefix: () async -> Bool,
        replayCommand: (Command) async -> ReplayResponse?,
        checkOracle: () async -> Bool
    ) async -> Bool {
        let depth = state.currentOrdering.count
        state.nodesVisited += 1

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

        if cachingEnabled {
            let cacheKey = mixCacheKey(observationSetHash, state.prefixHash, state.cursorHash)
            if state.prefixCache?.contains(cacheKey) == true {
                state.cacheHits += 1
                state.nodesPruned += 1
                return false
            }
            state.cacheMisses += 1
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
                state.nodesPruned += 1
                continue
            }

            if stepMismatches(observed: observation, replay: replay) {
                state.currentOrdering.append(placed)
                updateClosest(state.currentOrdering, matchDepth: depth, closestMatchDepth: &state.closestMatchDepth, closestOrdering: &state.closestOrdering)
                state.currentOrdering.removeLast()
                state.nodesPruned += 1
                continue
            }

            if observation.isSkipped == false, responsesMatch(observed: observation, replay: replay) == false {
                state.currentOrdering.append(placed)
                updateClosest(state.currentOrdering, matchDepth: depth, closestMatchDepth: &state.closestMatchDepth, closestOrdering: &state.closestOrdering)
                state.currentOrdering.removeLast()
                state.nodesPruned += 1
                continue
            }

            let observationHash = observationHashes?[laneIndex][cursor] ?? 0
            let prefixContribution = ZobristHash.mix(observationHash, at: depth)
            let oldCursorContribution = ZobristHash.mix(UInt64(cursor), at: laneIndex)
            let newCursorContribution = ZobristHash.mix(UInt64(cursor &+ 1), at: laneIndex)

            state.prefixHash ^= prefixContribution
            state.cursorHash ^= oldCursorContribution ^ newCursorContribution
            state.cursors[laneIndex] += 1
            state.currentOrdering.append(placed)

            let found = await searchIncrementallyAsync(
                totalCommands: totalCommands,
                observationHashes: observationHashes,
                cachingEnabled: cachingEnabled,
                observationSetHash: observationSetHash,
                state: &state,
                replayPrefix: replayPrefix,
                replayCommand: replayCommand,
                checkOracle: checkOracle
            )

            state.currentOrdering.removeLast()
            state.cursors[laneIndex] -= 1
            state.prefixHash ^= prefixContribution
            state.cursorHash ^= oldCursorContribution ^ newCursorContribution

            if found { return true }
        }

        if cachingEnabled {
            let cacheKey = mixCacheKey(observationSetHash, state.prefixHash, state.cursorHash)
            state.prefixCache?.insert(cacheKey)
        }

        return false
    }

    // MARK: - Shared Helpers (Search)

    private func computeObservationSetHash(_ observationHashes: [[UInt64]]?) -> UInt64 {
        var hash: UInt64 = 0
        if let observationHashes {
            for (laneIndex, lane) in observationHashes.enumerated() {
                for (commandIndex, commandHash) in lane.enumerated() {
                    hash ^= ZobristHash.mix(commandHash, at: laneIndex &* 256 &+ commandIndex)
                }
            }
        }
        return hash
    }

    private func logCacheStats(state: SearchState, totalCommands: Int, found: Bool) {
        if state.cacheHits + state.cacheMisses > 0 {
            ExhaustLog.debug(
                category: .propertyTest,
                event: "linearizability_cache",
                metadata: [
                    "commands": "\(totalCommands)",
                    "hits": "\(state.cacheHits)",
                    "misses": "\(state.cacheMisses)",
                    "nodes_visited": "\(state.nodesVisited)",
                    "nodes_pruned": "\(state.nodesPruned)",
                    "cache_entries": "\(state.prefixCache?.entries.count ?? 0)",
                    "result": found ? "linearizable" : "not_linearizable",
                ]
            )
        }
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

// MARK: - Cache Key Mixing

/// Combines the three cache key components into a single 64-bit key.
private func mixCacheKey(_ observationSetHash: UInt64, _ prefixHash: UInt64, _ cursorHash: UInt64) -> UInt64 {
    var combined = observationSetHash
    combined ^= prefixHash &* 0x9E37_79B9_7F4A_7C15
    combined ^= cursorHash &* 0x517C_C1B7_2722_0A95
    return ZobristHash.mix(combined, at: 0)
}
