import ExhaustCore

/// How a candidate was discovered, carrying the seed material each discovery method actually produces.
///
/// Merging the seed into the discovery case makes the unrepresentable states unconstructible: a screening candidate cannot lack its replay address, and no other candidate can carry one.
enum StateMachineCandidateProvenance {
    /// An SCA screening row: the covering-array seed whose row stream produced it, the sequence length of the tier it came from, and the 0-based row within that tier.
    case screening(coveringSeed: UInt64, tierLength: Int, rowInTier: Int)
    /// The fixed seed-0 sequential probe.
    case smokeTest
    /// Random sampling with the given PRNG seed.
    case randomSampling(seed: UInt64)
    /// A sampling replay with the given PRNG seed.
    case replay(seed: UInt64)

    var discoveryMethod: StateMachineDiscoveryMethod {
        switch self {
            case .screening: .screening
            case .smokeTest: .smokeTest
            case .randomSampling: .randomSampling
            case .replay: .replay
        }
    }

    /// Encodes the replay seed string for reproducing this candidate's failure.
    ///
    /// Screening candidates encode their full replay address as `{seed}-U{row}L{length}` (for example, `3RT5GH8KM2-U3L5` replays the third row of that seed's length-5 tier). Smoke tests encode a fixed seed. Random sampling and replay produce the standard seed-iteration format, taking `iteration` from the candidate.
    func encodeReplaySeed(iteration: Int) -> String {
        switch self {
            case let .screening(coveringSeed, tierLength, rowInTier):
                ReplaySeed.Resolved.screening(seed: coveringSeed, row: rowInTier, tierLength: tierLength).encoded
            case .smokeTest:
                ReplaySeed.Resolved.sampling(seed: 0, iteration: 1).encoded
            case let .randomSampling(seed), let .replay(seed):
                ReplaySeed.Resolved.sampling(seed: seed, iteration: iteration).encoded
        }
    }

    /// The seed for ``StateMachineResult/seed``: only those a sampling replay can consume.
    ///
    /// A screening candidate is addressed by covering-array row and a smoke test is a hardcoded zero. Neither addresses a point in a PRNG stream, so neither belongs in ``StateMachineResult/seed``. The screening address still reaches the user through ``StateMachineResult/replaySeed``.
    var resultSeed: UInt64? {
        switch self {
            case .screening, .smokeTest: nil
            case let .randomSampling(seed), let .replay(seed): seed
        }
    }
}

/// Carries a failing candidate from a source to the ``SpecMachine`` for reduction.
struct StateMachineCandidate<Spec: StateMachineSpecBase> {
    /// The full generated candidate: the setup step ahead of the tagged command sequence.
    let value: SpecCandidateValue<Spec>
    /// The full candidate tree. For a with-setup spec the root is the zip group; the machine decomposes it before pruning and reduction.
    let tree: ChoiceTree
    /// The command-side generator that produced this candidate's command child. Pruning and reduction must use it so the choice sequence stays consistent with the command child of `tree`. Smoke supplies a concurrency-1 generator, so a smoke-discovered failure reduces sequentially regardless of the run's lane count.
    let sequenceGen: Generator<[(ScheduleMarker, Spec.Command)]>
    let iteration: Int
    let provenance: StateMachineCandidateProvenance

    var discoveryMethod: StateMachineDiscoveryMethod {
        provenance.discoveryMethod
    }

    /// The PRNG seed command pruning draws from. A screening row comes from a covering array rather than a PRNG stream, so pruning gets a synthetic seed derived from the row's tier-local address, which discovery and a replay compute identically.
    var pruningSeed: UInt64 {
        switch provenance {
            case let .screening(_, _, rowInTier): UInt64(rowInTier)
            case .smokeTest: 0
            case let .randomSampling(seed), let .replay(seed): seed
        }
    }

    /// The seed the failure context reports: the PRNG seed for candidates a PRNG produced, and `nil` for screening, whose identity is a covering-array row rather than a position in a PRNG stream.
    var failureContextSeed: UInt64? {
        switch provenance {
            case .screening: nil
            case .smokeTest: 0
            case let .randomSampling(seed), let .replay(seed): seed
        }
    }
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
    /// Replays a single SCA screening row from a `{seed}-U{row}L{length}` seed.
    static func screeningReplay(
        coveringSeed: UInt64,
        tierLength: Int,
        row: Int,
        sequenceGen: Generator<[(ScheduleMarker, Spec.Command)]>,
        commandGen: Generator<Spec.Command>,
        commandLimit: Int,
        screeningBudget: UInt64,
        concurrencyLevel: Int?,
        leadingFactors: ScreeningLeadingFactors?,
        property: @escaping @Sendable (SpecCandidateValue<Spec>) -> Bool
    ) -> AnyStateMachineCandidateSource {
        .once(
            discoveryMethod: .screening,
            resolvedReplaySeed: .screening(seed: coveringSeed, row: row, tierLength: tierLength)
        ) {
            let result = __ExhaustRuntime.runSCAScreeningRowLoop(
                sequenceGen: sequenceGen,
                commandGen: commandGen,
                commandLimit: commandLimit,
                screeningBudget: screeningBudget,
                coveringSeed: coveringSeed,
                skipTo: (tierLength: tierLength, row: row),
                logEventPrefix: "statemachine_screening_replay",
                concurrencyLevel: concurrencyLevel,
                leadingFactors: leadingFactors,
                combine: __ExhaustRuntime.screeningCombine(Spec.self),
                property: property
            )

            switch result {
                case let .failure(value, tree, tierLength, rowInTier, screeningInvocations):
                    // Match the shape of a fresh screening candidate so the replayed failure round-trips to the seed it was replayed from.
                    return StateMachineCandidate(
                        value: value,
                        tree: tree,
                        sequenceGen: sequenceGen,
                        iteration: screeningInvocations,
                        provenance: .screening(coveringSeed: coveringSeed, tierLength: tierLength, rowInTier: rowInTier)
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
                iteration: Int(startIndex) + 1,
                provenance: .replay(seed: replaySeed)
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
                iteration: 0,
                provenance: .smokeTest
            )
        }
    }

    /// Iterates all SCA screening tiers until a failure is found or all rows exhaust.
    static func screening(
        sequenceGen: Generator<[(ScheduleMarker, Spec.Command)]>,
        commandGen: Generator<Spec.Command>,
        commandLimit: Int,
        screeningBudget: UInt64,
        coveringSeed: UInt64,
        concurrencyLevel: Int?,
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
                coveringSeed: coveringSeed,
                skipTo: nil,
                logEventPrefix: "statemachine_screening",
                concurrencyLevel: concurrencyLevel,
                sequenceGenForLength: sequenceGenForLength,
                leadingFactors: leadingFactors,
                combine: __ExhaustRuntime.screeningCombine(Spec.self),
                property: property
            )

            switch result {
                case let .failure(value, tree, tierLength, rowInTier, screeningInvocations):
                    return StateMachineCandidate(
                        value: value,
                        tree: tree,
                        sequenceGen: sequenceGen,
                        iteration: screeningInvocations,
                        provenance: .screening(coveringSeed: coveringSeed, tierLength: tierLength, rowInTier: rowInTier)
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
                        iteration: iteration,
                        provenance: .randomSampling(seed: seed)
                    )
                }
            }
            return nil
        }
    }
}
