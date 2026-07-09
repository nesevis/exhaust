import ExhaustCore

/// Carries a failing command sequence from a source to the ``SpecMachine`` for reduction.
struct StateMachineCandidate<Command> {
    let taggedCommands: [(ScheduleMarker, Command)]
    let tree: ChoiceTree
    /// The generator that produced this candidate. Pruning and reduction must use it so the choice sequence stays consistent with `tree`. Smoke supplies a concurrency-1 generator, so a smoke-discovered failure reduces sequentially regardless of the run's lane count.
    let sequenceGen: Generator<[(ScheduleMarker, Command)]>
    let seed: UInt64
    let iteration: Int
    let discoveryMethod: StateMachineDiscoveryMethod
}

/// Produces failing candidate command sequences for the ``SpecMachine``, owning its iteration state internally.
struct AnyStateMachineCandidateSource<Command> {
    /// Which discovery phase this source represents. The machine attributes the source's invocations and wall time to the matching report bucket whether or not the source yields a candidate, so a phase that runs and passes is still counted.
    let discoveryMethod: StateMachineDiscoveryMethod
    /// The PRNG seed to surface in ``ExhaustReport/seed``, or `nil` for phases with no replayable seed (coverage, smoke).
    let reportedSeed: UInt64?
    let resolvedReplaySeed: ReplaySeed.Resolved?
    private let produceNext: () throws -> StateMachineCandidate<Command>?

    init(
        discoveryMethod: StateMachineDiscoveryMethod = .randomSampling,
        reportedSeed: UInt64? = nil,
        resolvedReplaySeed: ReplaySeed.Resolved? = nil,
        _ produceNext: @escaping () throws -> StateMachineCandidate<Command>?
    ) {
        self.discoveryMethod = discoveryMethod
        self.reportedSeed = reportedSeed
        self.resolvedReplaySeed = resolvedReplaySeed
        self.produceNext = produceNext
    }

    func next() throws -> StateMachineCandidate<Command>? {
        try produceNext()
    }
}

// MARK: - Combinators

extension AnyStateMachineCandidateSource {
    /// A source that evaluates its computation at most once, then returns nil forever.
    private static func once(
        discoveryMethod: StateMachineDiscoveryMethod,
        reportedSeed: UInt64? = nil,
        resolvedReplaySeed: ReplaySeed.Resolved? = nil,
        _ computation: @escaping () throws -> StateMachineCandidate<Command>?
    ) -> AnyStateMachineCandidateSource {
        var exhausted = false
        return AnyStateMachineCandidateSource(
            discoveryMethod: discoveryMethod,
            reportedSeed: reportedSeed,
            resolvedReplaySeed: resolvedReplaySeed
        ) {
            guard exhausted == false else {
                return nil
            }
            exhausted = true
            return try computation()
        }
    }
}

// MARK: - Source Factories

extension AnyStateMachineCandidateSource {
    /// Replays a single SCA coverage row from a `U-{N}` seed.
    static func coverageReplay(
        row: Int,
        sequenceGen: Generator<[(ScheduleMarker, Command)]>,
        commandGen: Generator<Command>,
        commandLimit: Int,
        coverageBudget: UInt64,
        concurrencyLevel: Int,
        property: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Bool
    ) -> AnyStateMachineCandidateSource {
        .once(discoveryMethod: .coverage, resolvedReplaySeed: .coverage(row: row)) {
            let result = __ExhaustRuntime.runSCACoverageRowLoop(
                sequenceGen: sequenceGen,
                commandGen: commandGen,
                commandLimit: commandLimit,
                coverageBudget: coverageBudget,
                skipToRow: row,
                logEventPrefix: "statemachine_coverage_replay",
                concurrencyLevel: concurrencyLevel,
                property: property
            )

            switch result {
                case let .failure(value, tree, coverageInvocations):
                    // Match the shape of a fresh coverage candidate so the replayed failure round-trips to the same `U-N` seed and nils its synthetic seed.
                    return StateMachineCandidate(
                        taggedCommands: value,
                        tree: tree,
                        sequenceGen: sequenceGen,
                        seed: UInt64(coverageInvocations),
                        iteration: coverageInvocations,
                        discoveryMethod: .coverage
                    )
                case .completed, .skipped:
                    return nil
            }
        }
    }

    /// Replays a single sampling seed by jumping directly to the target PRNG state via `initialRunIndex`.
    static func samplingReplay(
        replaySeed: UInt64,
        replayIteration: Int?,
        sequenceGen: Generator<[(ScheduleMarker, Command)]>,
        property: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Bool
    ) -> AnyStateMachineCandidateSource {
        .once(
            discoveryMethod: .replay,
            reportedSeed: replaySeed,
            resolvedReplaySeed: .sampling(seed: replaySeed, iteration: replayIteration)
        ) {
            let startIndex = replayIteration.map { UInt64($0 - 1) } ?? 0
            var interpreter = ValueAndChoiceTreeInterpreter(
                sequenceGen,
                seed: replaySeed,
                maxRuns: startIndex + 1,
                initialRunIndex: startIndex
            )
            guard let (value, tree) = try interpreter.next() else {
                return nil
            }
            guard property(value) == false else {
                return nil
            }
            return StateMachineCandidate(
                taggedCommands: value,
                tree: tree,
                sequenceGen: sequenceGen,
                seed: replaySeed,
                iteration: Int(startIndex) + 1,
                discoveryMethod: .replay
            )
        }
    }

    /// Seed 0, one sequential probe to catch obvious breakage before concurrent phases.
    static func smoke(
        sequenceGen: Generator<[(ScheduleMarker, Command)]>,
        property: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Bool
    ) -> AnyStateMachineCandidateSource {
        .once(discoveryMethod: .smokeTest) {
            var interpreter = ValueAndChoiceTreeInterpreter(sequenceGen, seed: 0, maxRuns: 1)
            guard let (value, tree) = try interpreter.next() else {
                return nil
            }
            guard property(value) == false else {
                return nil
            }
            return StateMachineCandidate(
                taggedCommands: value,
                tree: tree,
                sequenceGen: sequenceGen,
                seed: 0,
                iteration: 0,
                discoveryMethod: .smokeTest
            )
        }
    }

    /// Iterates all SCA coverage tiers until a failure is found or all rows exhaust.
    static func coverage(
        sequenceGen: Generator<[(ScheduleMarker, Command)]>,
        commandGen: Generator<Command>,
        commandLimit: Int,
        coverageBudget: UInt64,
        concurrencyLevel: Int,
        sequenceGenForLength: ((ClosedRange<UInt64>) -> Generator<[(ScheduleMarker, Command)]>)? = nil,
        property: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Bool
    ) -> AnyStateMachineCandidateSource {
        .once(discoveryMethod: .coverage) {
            let result = __ExhaustRuntime.runSCACoverageRowLoop(
                sequenceGen: sequenceGen,
                commandGen: commandGen,
                commandLimit: commandLimit,
                coverageBudget: coverageBudget,
                skipToRow: nil,
                logEventPrefix: "statemachine_coverage",
                concurrencyLevel: concurrencyLevel,
                sequenceGenForLength: sequenceGenForLength,
                property: property
            )

            switch result {
                case let .failure(value, tree, coverageInvocations):
                    return StateMachineCandidate(
                        taggedCommands: value,
                        tree: tree,
                        sequenceGen: sequenceGen,
                        seed: UInt64(coverageInvocations),
                        iteration: coverageInvocations,
                        discoveryMethod: .coverage
                    )
                case .completed, .skipped:
                    return nil
            }
        }
    }

    /// Random sampling via VACTI, budget-capped.
    static func sampling(
        sequenceGen: Generator<[(ScheduleMarker, Command)]>,
        seed: UInt64,
        samplingBudget: UInt64,
        property: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Bool
    ) -> AnyStateMachineCandidateSource {
        var interpreter = ValueAndChoiceTreeInterpreter(
            sequenceGen,
            seed: seed,
            maxRuns: samplingBudget
        )
        var iteration = 0
        return AnyStateMachineCandidateSource(discoveryMethod: .randomSampling, reportedSeed: seed) {
            while let value = try interpreter.nextValueOnly() {
                iteration += 1
                if property(value) == false {
                    let tree = try interpreter.reproduceFailureTree()
                    return StateMachineCandidate(
                        taggedCommands: value,
                        tree: tree,
                        sequenceGen: sequenceGen,
                        seed: seed,
                        iteration: iteration,
                        discoveryMethod: .randomSampling
                    )
                }
            }
            return nil
        }
    }
}
