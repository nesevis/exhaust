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

/// Type-erased source that produces failing candidate command sequences for the ``ContractMachine``. Each source owns its iteration state internally.
struct AnyContractCandidateSource<Command> {
    private let produceNext: () -> ContractCandidate<Command>?

    init(_ produceNext: @escaping () -> ContractCandidate<Command>?) {
        self.produceNext = produceNext
    }

    func next() -> ContractCandidate<Command>? {
        produceNext()
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
        var exhausted = false
        return AnyContractCandidateSource {
            guard exhausted == false else { return nil }
            exhausted = true

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

    /// Replays a single sampling seed.
    static func samplingReplay(
        replaySeed: UInt64,
        replayIteration: Int?,
        sequenceGen: Generator<[(ScheduleMarker, Command)]>,
        property: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Bool
    ) -> AnyContractCandidateSource {
        var exhausted = false
        return AnyContractCandidateSource {
            guard exhausted == false else { return nil }
            exhausted = true

            var interpreter = ValueAndChoiceTreeInterpreter(
                sequenceGen,
                seed: replaySeed,
                maxRuns: UInt64((replayIteration ?? 0) + 1)
            )
            var currentIteration = 0
            while let (value, tree) = try? interpreter.next() {
                defer { currentIteration += 1 }
                if currentIteration == (replayIteration ?? 0) {
                    if property(value) == false {
                        return ContractCandidate(
                            taggedCommands: value,
                            tree: tree,
                            seed: replaySeed,
                            iteration: currentIteration,
                            discoveryMethod: .replay,
                            sourceInvocations: currentIteration + 1
                        )
                    }
                }
            }
            return nil
        }
    }

    /// Seed 0, one sequential probe to catch obvious breakage before concurrent phases.
    static func smoke(
        sequenceGen: Generator<[(ScheduleMarker, Command)]>,
        property: @escaping @Sendable ([(ScheduleMarker, Command)]) -> Bool
    ) -> AnyContractCandidateSource {
        var exhausted = false
        return AnyContractCandidateSource {
            guard exhausted == false else { return nil }
            exhausted = true

            var interpreter = ValueAndChoiceTreeInterpreter(sequenceGen, seed: 0, maxRuns: 1)
            guard let (value, tree) = try? interpreter.next() else { return nil }
            if property(value) == false {
                return ContractCandidate(
                    taggedCommands: value,
                    tree: tree,
                    seed: 0,
                    iteration: 0,
                    discoveryMethod: .smokeTest,
                    sourceInvocations: 1
                )
            }
            return nil
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
        var exhausted = false
        return AnyContractCandidateSource {
            guard exhausted == false else { return nil }
            exhausted = true

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
            while let (value, tree) = try? interpreter.next() {
                let currentIteration = iteration
                iteration += 1
                if property(value) == false {
                    return ContractCandidate(
                        taggedCommands: value,
                        tree: tree,
                        seed: seed,
                        iteration: currentIteration,
                        discoveryMethod: .randomSampling,
                        sourceInvocations: iteration
                    )
                }
            }
            return nil
        }
    }
}
