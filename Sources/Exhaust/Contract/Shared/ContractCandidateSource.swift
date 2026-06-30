import ExhaustCore

/// Carries a failing command sequence from a source to the ``ContractMachine`` for reduction.
struct ContractCandidate<Command> {
    let taggedCommands: [(ScheduleMarker, Command)]
    let tree: ChoiceTree
    let seed: UInt64
    let iteration: Int
    let discoveryMethod: ContractDiscoveryMethod
    let sourceInvocations: Int
}

/// Produces failing candidate command sequences for the ``ContractMachine``, owning its iteration state internally.
struct AnyContractCandidateSource<Command> {
    let resolvedReplaySeed: ReplaySeed.Resolved?
    private let produceNext: () throws -> ContractCandidate<Command>?

    init(
        resolvedReplaySeed: ReplaySeed.Resolved? = nil,
        _ produceNext: @escaping () throws -> ContractCandidate<Command>?
    ) {
        self.resolvedReplaySeed = resolvedReplaySeed
        self.produceNext = produceNext
    }

    func next() throws -> ContractCandidate<Command>? {
        try produceNext()
    }
}

// MARK: - Combinators

extension AnyContractCandidateSource {
    /// A source that evaluates its computation at most once, then returns nil forever.
    private static func once(
        resolvedReplaySeed: ReplaySeed.Resolved? = nil,
        _ computation: @escaping () throws -> ContractCandidate<Command>?
    ) -> AnyContractCandidateSource {
        var exhausted = false
        return AnyContractCandidateSource(resolvedReplaySeed: resolvedReplaySeed) {
            guard exhausted == false else {
                return nil
            }
            exhausted = true
            return try computation()
        }
    }
}

// MARK: - Source Factories

extension AnyContractCandidateSource {
    /// Replays a single SCA coverage row from a `U-{N}` seed.
    static func coverageReplay(
        row: Int,
        sequenceGen: Generator<[(ScheduleMarker, Command)]>,
        commandGen: Generator<Command>,
        commandLimit: Int,
        coverageBudget: UInt64,
        concurrencyLevel: Int,
        property: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Bool
    ) -> AnyContractCandidateSource {
        .once(resolvedReplaySeed: .coverage(row: row)) {
            let result = __ExhaustRuntime.runSCACoverageRowLoop(
                sequenceGen: sequenceGen,
                commandGen: commandGen,
                commandLimit: commandLimit,
                coverageBudget: coverageBudget,
                skipToRow: row,
                logEventPrefix: "contract_coverage_replay",
                concurrencyLevel: concurrencyLevel,
                property: property
            )

            switch result {
                case let .failure(value, tree, coverageInvocations):
                    return ContractCandidate(
                        taggedCommands: value,
                        tree: tree,
                        seed: UInt64(row),
                        iteration: row,
                        discoveryMethod: .replay,
                        sourceInvocations: coverageInvocations
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
    ) -> AnyContractCandidateSource {
        .once(resolvedReplaySeed: .sampling(seed: replaySeed, iteration: replayIteration)) {
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
            return ContractCandidate(
                taggedCommands: value,
                tree: tree,
                seed: replaySeed,
                iteration: Int(startIndex) + 1,
                discoveryMethod: .replay,
                sourceInvocations: 1
            )
        }
    }

    /// Seed 0, one sequential probe to catch obvious breakage before concurrent phases.
    static func smoke(
        sequenceGen: Generator<[(ScheduleMarker, Command)]>,
        property: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Bool
    ) -> AnyContractCandidateSource {
        .once {
            var interpreter = ValueAndChoiceTreeInterpreter(sequenceGen, seed: 0, maxRuns: 1)
            guard let (value, tree) = try interpreter.next() else {
                return nil
            }
            guard property(value) == false else {
                return nil
            }
            return ContractCandidate(
                taggedCommands: value,
                tree: tree,
                seed: 0,
                iteration: 0,
                discoveryMethod: .smokeTest,
                sourceInvocations: 1
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
    ) -> AnyContractCandidateSource {
        .once {
            let result = __ExhaustRuntime.runSCACoverageRowLoop(
                sequenceGen: sequenceGen,
                commandGen: commandGen,
                commandLimit: commandLimit,
                coverageBudget: coverageBudget,
                skipToRow: nil,
                logEventPrefix: "contract_coverage",
                concurrencyLevel: concurrencyLevel,
                sequenceGenForLength: sequenceGenForLength,
                property: property
            )

            switch result {
                case let .failure(value, tree, coverageInvocations):
                    return ContractCandidate(
                        taggedCommands: value,
                        tree: tree,
                        seed: UInt64(coverageInvocations),
                        iteration: coverageInvocations,
                        discoveryMethod: .coverage,
                        sourceInvocations: coverageInvocations
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
    ) -> AnyContractCandidateSource {
        var interpreter = ValueAndChoiceTreeInterpreter(
            sequenceGen,
            seed: seed,
            maxRuns: samplingBudget
        )
        var iteration = 0
        return AnyContractCandidateSource {
            while let value = try interpreter.nextValueOnly() {
                iteration += 1
                if property(value) == false {
                    let tree = try interpreter.reproduceFailureTree()
                    return ContractCandidate(
                        taggedCommands: value,
                        tree: tree,
                        seed: seed,
                        iteration: iteration,
                        discoveryMethod: .randomSampling,
                        sourceInvocations: iteration
                    )
                }
            }
            return nil
        }
    }
}
