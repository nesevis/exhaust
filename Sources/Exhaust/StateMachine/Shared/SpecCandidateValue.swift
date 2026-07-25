import ExhaustCore

/// Carries one generated spec candidate through the pipeline: the setup step values ahead of the tagged command sequence.
///
/// `setupSteps` holds zero or one element: empty for specs without a `@Setup` method, one for specs with one. The array keeps the executor splice loop and the zero-setup path uniform, and survives a future lift of the one-method restriction unchanged. Setup steps never enter `taggedCommands`, so lane partitioning, skip indices, and per-element segments keep their command-array index bases.
struct SpecCandidateValue<Spec: StateMachineSpecBase>: Sendable {
    var setupSteps: [Spec.SetupStep]
    var taggedCommands: [(ScheduleMarker, Spec.Command)]
}

extension __ExhaustRuntime {
    /// Builds the full candidate generator from the command-sequence generator, routing on the spec's `setupGenerator`.
    ///
    /// The two paths are deliberately different shapes. With setup, the candidate is a zip of the setup step ahead of the command sequence, so setup lives in the choice tree and reduces. Without setup, the candidate MUST be a pure `.map` over the command-sequence generator: a zip against a trivial generator would emit a marker into the flat choice sequence, shifting every index and invalidating every recorded regression seed for every existing spec.
    static func specCandidateGenerator<Spec: StateMachineSpecBase>(
        _: Spec.Type,
        sequenceGen: Generator<[(ScheduleMarker, Spec.Command)]>
    ) -> Generator<SpecCandidateValue<Spec>> {
        guard let setupGen = Spec.setupGenerator else {
            return sequenceGen.map { SpecCandidateValue(setupSteps: [], taggedCommands: $0) }
        }
        return Gen.zip(setupGen.gen, sequenceGen).map { pair in
            SpecCandidateValue(setupSteps: [pair.0], taggedCommands: pair.1)
        }
    }
}

// MARK: - Candidate Tree Decomposition

extension __ExhaustRuntime {
    /// Splits a with-setup candidate tree into its setup and command children.
    ///
    /// `Gen.zip` materializes as `.group([setupTree, commandTree], isOpaque: false)` and the candidate's outer `.map` is tree-transparent, so the root of a with-setup candidate tree is exactly that two-child group. Returns `nil` when the shape does not match; callers must degrade safely (skip reduction) rather than operate on a tree they cannot decompose.
    static func splitCandidateTree(_ tree: ChoiceTree) -> (setupTree: ChoiceTree, commandTree: ChoiceTree)? {
        guard case let .group(children, _) = tree, children.count == 2 else {
            return nil
        }
        return (children[0], children[1])
    }

    /// Recomposes a full candidate tree from its setup and command children, mirroring the shape `Gen.zip` materializes.
    static func composeCandidateTree(setupTree: ChoiceTree, commandTree: ChoiceTree) -> ChoiceTree {
        .group([setupTree, commandTree], isOpaque: false)
    }
}
