import ExhaustCore

/// Carries a failing candidate from a source to the ``SpecMachine`` for reduction.
struct StateMachineCandidate<Spec: StateMachineSpecBase> {
    /// The full generated candidate: the setup step ahead of the tagged command sequence.
    let value: SpecCandidateValue<Spec>
    /// The full candidate tree. For a with-setup spec the root is the zip group; the machine decomposes it before pruning and reduction.
    let tree: ChoiceTree
    /// The command-side generator that produced this candidate's command child. Pruning and reduction must use it so the choice sequence stays consistent with the command child of `tree`. Smoke supplies a concurrency-1 generator, so a smoke-discovered failure reduces sequentially regardless of the run's lane count.
    let sequenceGen: Generator<[(ScheduleMarker, Spec.Command)]>
    let seed: UInt64
    let iteration: Int
    let discoveryMethod: StateMachineDiscoveryMethod
}

/// Produces failing candidates for the ``SpecMachine``, owning its iteration state internally.
struct AnyStateMachineCandidateSource<Spec: StateMachineSpecBase> {
    /// Which discovery phase this source represents. The machine attributes the source's invocations and wall time to the matching report bucket whether or not the source yields a candidate, so a phase that runs and passes is still counted.
    let discoveryMethod: StateMachineDiscoveryMethod
    /// The PRNG seed to surface in ``ExhaustReport/seed``, or `nil` for phases with no replayable seed (screening, smoke).
    let reportedSeed: UInt64?
    let resolvedReplaySeed: ReplaySeed.Resolved?
    private let produceNext: () throws -> StateMachineCandidate<Spec>?

    init(
        discoveryMethod: StateMachineDiscoveryMethod = .randomSampling,
        reportedSeed: UInt64? = nil,
        resolvedReplaySeed: ReplaySeed.Resolved? = nil,
        _ produceNext: @escaping () throws -> StateMachineCandidate<Spec>?
    ) {
        self.discoveryMethod = discoveryMethod
        self.reportedSeed = reportedSeed
        self.resolvedReplaySeed = resolvedReplaySeed
        self.produceNext = produceNext
    }

    func next() throws -> StateMachineCandidate<Spec>? {
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
        _ computation: @escaping () throws -> StateMachineCandidate<Spec>?
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
    /// Replays a single SCA screening row from a `U-{N}` seed.
    static func screeningReplay(
        row: Int,
        sequenceGen: Generator<[(ScheduleMarker, Spec.Command)]>,
        commandGen: Generator<Spec.Command>,
        commandLimit: Int,
        screeningBudget: UInt64,
        concurrencyLevel: Int,
        leadingFactors: ScreeningLeadingFactors?,
        property: @escaping @Sendable (SpecCandidateValue<Spec>) -> Bool
    ) -> AnyStateMachineCandidateSource {
        .once(discoveryMethod: .screening, resolvedReplaySeed: .screening(row: row)) {
            let result = __ExhaustRuntime.runSCAScreeningRowLoop(
                sequenceGen: sequenceGen,
                commandGen: commandGen,
                commandLimit: commandLimit,
                screeningBudget: screeningBudget,
                skipToRow: row,
                logEventPrefix: "statemachine_screening_replay",
                concurrencyLevel: concurrencyLevel,
                leadingFactors: leadingFactors,
                combine: { setupTree, taggedCommands, commandTree in
                    __ExhaustRuntime.combineScreeningCandidate(
                        Spec.self,
                        setupTree: setupTree,
                        taggedCommands: taggedCommands,
                        commandTree: commandTree
                    )
                },
                property: property
            )

            switch result {
                case let .failure(value, tree, screeningInvocations):
                    // Match the shape of a fresh screening candidate so the replayed failure round-trips to the same `U-N` seed and nils its synthetic seed.
                    return StateMachineCandidate(
                        value: value,
                        tree: tree,
                        sequenceGen: sequenceGen,
                        seed: UInt64(screeningInvocations),
                        iteration: screeningInvocations,
                        discoveryMethod: .screening
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
        sequenceGen: Generator<[(ScheduleMarker, Spec.Command)]>,
        property: @escaping @Sendable (SpecCandidateValue<Spec>) -> Bool
    ) -> AnyStateMachineCandidateSource {
        .once(
            discoveryMethod: .replay,
            reportedSeed: replaySeed,
            resolvedReplaySeed: .sampling(seed: replaySeed, iteration: replayIteration)
        ) {
            let startIndex = replayIteration.map { UInt64($0 - 1) } ?? 0
            var interpreter = ValueAndChoiceTreeInterpreter(
                __ExhaustRuntime.specCandidateGenerator(Spec.self, sequenceGen: sequenceGen),
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
                value: value,
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
        sequenceGen: Generator<[(ScheduleMarker, Spec.Command)]>,
        property: @escaping @Sendable (SpecCandidateValue<Spec>) -> Bool
    ) -> AnyStateMachineCandidateSource {
        .once(discoveryMethod: .smokeTest) {
            let candidateGen = __ExhaustRuntime.specCandidateGenerator(Spec.self, sequenceGen: sequenceGen)
            var interpreter = ValueAndChoiceTreeInterpreter(candidateGen, seed: 0, maxRuns: 1)
            guard let (value, tree) = try interpreter.next() else {
                return nil
            }
            guard property(value) == false else {
                return nil
            }
            return StateMachineCandidate(
                value: value,
                tree: tree,
                sequenceGen: sequenceGen,
                seed: 0,
                iteration: 0,
                discoveryMethod: .smokeTest
            )
        }
    }

    /// Iterates all SCA screening tiers until a failure is found or all rows exhaust.
    static func screening(
        sequenceGen: Generator<[(ScheduleMarker, Spec.Command)]>,
        commandGen: Generator<Spec.Command>,
        commandLimit: Int,
        screeningBudget: UInt64,
        concurrencyLevel: Int,
        sequenceGenForLength: ((ClosedRange<UInt64>) -> Generator<[(ScheduleMarker, Spec.Command)]>)? = nil,
        leadingFactors: ScreeningLeadingFactors?,
        property: @escaping @Sendable (SpecCandidateValue<Spec>) -> Bool
    ) -> AnyStateMachineCandidateSource {
        .once(discoveryMethod: .screening) {
            let result = __ExhaustRuntime.runSCAScreeningRowLoop(
                sequenceGen: sequenceGen,
                commandGen: commandGen,
                commandLimit: commandLimit,
                screeningBudget: screeningBudget,
                skipToRow: nil,
                logEventPrefix: "statemachine_screening",
                concurrencyLevel: concurrencyLevel,
                sequenceGenForLength: sequenceGenForLength,
                leadingFactors: leadingFactors,
                combine: { setupTree, taggedCommands, commandTree in
                    __ExhaustRuntime.combineScreeningCandidate(
                        Spec.self,
                        setupTree: setupTree,
                        taggedCommands: taggedCommands,
                        commandTree: commandTree
                    )
                },
                property: property
            )

            switch result {
                case let .failure(value, tree, screeningInvocations):
                    return StateMachineCandidate(
                        value: value,
                        tree: tree,
                        sequenceGen: sequenceGen,
                        seed: UInt64(screeningInvocations),
                        iteration: screeningInvocations,
                        discoveryMethod: .screening
                    )
                case .completed, .skipped:
                    return nil
            }
        }
    }

    /// Random sampling via VACTI, budget-capped.
    static func sampling(
        sequenceGen: Generator<[(ScheduleMarker, Spec.Command)]>,
        seed: UInt64,
        samplingBudget: UInt64,
        property: @escaping @Sendable (SpecCandidateValue<Spec>) -> Bool
    ) -> AnyStateMachineCandidateSource {
        var interpreter = ValueAndChoiceTreeInterpreter(
            __ExhaustRuntime.specCandidateGenerator(Spec.self, sequenceGen: sequenceGen),
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
                        value: value,
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
