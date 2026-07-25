// Candidate source construction for spec machine runs.
import ExhaustCore
import Foundation

extension __ExhaustRuntime {
    /// Builds a sequential property for the smoke source: runs commands in order, checks invariants after each step.
    ///
    /// Shared by all spec backends. The sync variant handles `StateMachineSpec`; the async variant bridges through `_blockingAwaitSemaphore`. Both are used as the smoke source's property closure and as the sequential backend's probe property.
    static func syncSequentialProperty<Spec: StateMachineSpec>(_ specType: Spec.Type) -> @Sendable (SpecCandidateValue<Spec>) -> Bool {
        let verdictProperty = syncSequentialVerdictProperty(specType)
        return { candidate in
            verdictProperty(candidate).isFailure == false
        }
    }

    /// The one sequential executor loop, returning a verdict: preserves the thrown error as the failure symptom, so the `time:` runner's reduction gate can tell invariant violations (`StateMachineCheckFailure`) apart from user-thrown error types instead of collapsing every spec fault into one capped symptom. ``syncSequentialProperty(_:)`` derives the Bool probe from this, so the two can never disagree on what passes. The setup step runs first as the head of the sequential prefix; a setup throw fails the run with the thrown error as the symptom.
    static func syncSequentialVerdictProperty<Spec: StateMachineSpec>(_: Spec.Type) -> @Sendable (SpecCandidateValue<Spec>) -> FuzzVerdict {
        { candidate in
            let (spec, setupError) = Spec.makeSpec(setupStep: candidate.setupStep)
            if let setupError {
                return .fail(.thrown(setupError))
            }
            for (_, command) in candidate.taggedCommands {
                do {
                    try spec.run(command)
                    try spec.checkInvariants()
                } catch is StateMachineSkip {
                    continue
                } catch {
                    return .fail(.thrown(error))
                }
            }
            return .pass
        }
    }

    /// The one async sequential executor loop, returning a verdict: the async twin of ``syncSequentialVerdictProperty(_:)``, bridging through `_blockingAwaitSemaphore` and preserving the thrown error as the failure symptom. ``asyncSequentialProperty(specInit:)`` derives the Bool probe from this, so the two can never disagree on what passes.
    static func asyncSequentialVerdictProperty<Spec: AsyncStateMachineSpec>(
        specInit: @escaping () -> Spec
    ) -> @Sendable (SpecCandidateValue<Spec>) -> FuzzVerdict {
        nonisolated(unsafe) let specInit = specInit
        return { candidate in
            let verdict: FuzzVerdict? = _blockingAwaitSemaphore(timeoutMilliseconds: nil) {
                let spec = specInit()
                if let setupError = await spec.applySetup(candidate.setupStep) {
                    return FuzzVerdict.fail(.thrown(setupError))
                }
                for (_, command) in candidate.taggedCommands {
                    do {
                        try await spec.run(command)
                        try await spec.checkInvariants()
                    } catch is StateMachineSkip {
                        continue
                    } catch {
                        return FuzzVerdict.fail(.thrown(error))
                    }
                }
                return FuzzVerdict.pass
            }
            // Unreachable with a nil timeout; kept as the fail-safe direction the Bool probe has always had.
            return verdict ?? .fail(.returnedFalse)
        }
    }

    /// Async variant of the sequential smoke property, derived from ``asyncSequentialVerdictProperty(specInit:)``.
    static func asyncSequentialProperty<Spec: AsyncStateMachineSpec>(
        specInit: @escaping () -> Spec
    ) -> @Sendable (SpecCandidateValue<Spec>) -> Bool {
        let verdictProperty = asyncSequentialVerdictProperty(specInit: specInit)
        return { candidate in
            verdictProperty(candidate).isFailure == false
        }
    }
}

extension __ExhaustRuntime {
    /// Builds the prioritized source array for a spec machine run.
    ///
    /// Source order matches the design document: screening replay, sampling replay, smoke, screening, sampling. Each source is independently gated by the config. The smoke source is entry-point-specific (sequential has none, cooperative and preemptive construct different property closures), so it is passed in pre-built.
    static func buildStateMachineSources<Spec: StateMachineSpecBase>(
        config: ResolvedConcurrentConfig,
        sequenceGen: Generator<[(ScheduleMarker, Spec.Command)]>,
        commandGen: Generator<Spec.Command>,
        commandLimit: Int,
        concurrencyLevel: Int,
        property: @escaping @Sendable (SpecCandidateValue<Spec>) -> Bool,
        smokeSource: AnyStateMachineCandidateSource<Spec>? = nil,
        sequenceGenForLength: ((ClosedRange<UInt64>) -> Generator<[(ScheduleMarker, Spec.Command)]>)? = nil
    ) -> [AnyStateMachineCandidateSource<Spec>] {
        var sources: [AnyStateMachineCandidateSource<Spec>] = []
        let leadingFactors = setupScreeningFactors(for: Spec.self)

        if let row = config.screeningReplayRow {
            sources.append(.screeningReplay(
                row: row,
                sequenceGen: sequenceGen,
                commandGen: commandGen,
                commandLimit: commandLimit,
                screeningBudget: max(UInt64(config.budget.screeningBudget), UInt64(row) + 1),
                concurrencyLevel: concurrencyLevel,
                leadingFactors: leadingFactors,
                property: property
            ))
        }

        if let replayIteration = config.replayIteration, let seed = config.seed {
            sources.append(.samplingReplay(
                replaySeed: seed,
                replayIteration: replayIteration,
                sequenceGen: sequenceGen,
                property: property
            ))
        }

        if let smokeSource {
            sources.append(smokeSource)
        }

        if config.shouldRunScreening {
            sources.append(.screening(
                sequenceGen: sequenceGen,
                commandGen: commandGen,
                commandLimit: commandLimit,
                screeningBudget: UInt64(config.budget.screeningBudget),
                concurrencyLevel: concurrencyLevel,
                sequenceGenForLength: sequenceGenForLength,
                leadingFactors: leadingFactors,
                property: property
            ))
        }

        if config.replayIteration == nil, config.screeningReplayRow == nil {
            let seed = config.seed ?? Xoshiro256().seed
            sources.append(.sampling(
                sequenceGen: sequenceGen,
                seed: seed,
                samplingBudget: UInt64(config.budget.samplingBudget),
                property: property
            ))
        }

        return sources
    }

    /// Covering-array factors for a spec's `@Setup` generator, or `nil` for a spec without one.
    ///
    /// Setup arguments become factors in the same covering array as the command positions, so strength-2 coverage pairs every setup value with every command type at every position. A setup method's arguments are worth that budget in a way a command's arguments are not: there is at most one setup method, so its factors add a fixed block rather than multiplying across positions and lanes, and its values configure the SUT for every command that follows.
    ///
    /// The analysis is deliberately budget-independent. Passing the screening budget as a composite threshold would make the factor domains vary with the budget, and a `U-{N}` replay runs under a different budget than discovery did — the covering array would differ and the replay would land on another row.
    static func setupScreeningFactors<Spec: StateMachineSpecBase>(
        for _: Spec.Type
    ) -> ScreeningLeadingFactors? {
        guard let setupGen = Spec.setupGenerator,
              let analysis = ChoiceTreeAnalysis.analyze(setupGen.gen)
        else {
            return nil
        }
        switch analysis {
            case let .enumerable(profile):
                return ScreeningLeadingFactors(
                    domainSizes: profile.parameters.map(\.domainSize),
                    buildTree: { CoveringArrayReplay.buildTree(row: $0, profile: profile) }
                )
            case let .large(profile):
                return ScreeningLeadingFactors(
                    domainSizes: profile.parameters.map(\.domainSize),
                    buildTree: { profile.buildTree(from: $0) }
                )
        }
    }

    /// Materializes a screening row's setup subtree and joins it to the row's command sequence.
    ///
    /// The two halves are materialized against their own generators and joined with ``composeCandidateTree(setupTree:commandTree:)`` — the same node `Gen.zip` produces — so the candidate tree is correct by construction rather than by a fallback-shape guess. Returns `nil` to skip a row whose setup will not materialize.
    static func combineScreeningCandidate<Spec: StateMachineSpecBase>(
        _: Spec.Type,
        setupTree: ChoiceTree?,
        taggedCommands: [(ScheduleMarker, Spec.Command)],
        commandTree: ChoiceTree
    ) -> (value: SpecCandidateValue<Spec>, tree: ChoiceTree)? {
        guard let setupGen = Spec.setupGenerator, let setupTree else {
            return (SpecCandidateValue(setupStep: nil, taggedCommands: taggedCommands), commandTree)
        }
        // seed 0: the covering array already pins every analyzed setup factor, so the seed only fills choices the
        // analysis could not model, and a fixed seed keeps a `U-{N}` replay landing on the same setup value.
        guard case let .success(step, freshSetupTree, _) = Materializer.materialize(
            setupGen.gen,
            prefix: ChoiceSequence(),
            mode: .guided(seed: 0, fallbackTree: setupTree)
        ) else {
            return nil
        }
        return (
            SpecCandidateValue(setupStep: step, taggedCommands: taggedCommands),
            composeCandidateTree(setupTree: freshSetupTree, commandTree: commandTree)
        )
    }
}

/// An independent block of covering-array factors belonging to a different generator than the screening row's.
///
/// The factors join the row's covering array so interactions between the two blocks are covered, but the block's slice of each row is replayed through its own generator rather than folded into the row's fallback tree.
struct ScreeningLeadingFactors {
    let domainSizes: [UInt64]
    let buildTree: (CoveringArrayRow) -> ChoiceTree?
}

extension __ExhaustRuntime {
    /// Builds the sequential command-sequence generator: up to `commandLimit` commands at constant scaling, each tagged with `ScheduleMarker.prefix`.
    ///
    /// Shared by plain `#execute`'s sequential entry points and the `time:` spec adapter, so the sequence shape (length range, scaling, marker tagging) cannot drift between the modes.
    static func taggedSequenceGenerator<Command>(
        commandGen: ReflectiveGenerator<Command>,
        commandLimit: Int
    ) -> Generator<[(ScheduleMarker, Command)]> {
        commandGen.array(length: 0 ... commandLimit, scaling: .constant).gen.map { commands in
            commands.map { (ScheduleMarker.prefix, $0) }
        }
    }
}
