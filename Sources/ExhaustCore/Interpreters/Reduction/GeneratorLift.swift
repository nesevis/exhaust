// MARK: - Generator Lift

/// Lifts a raw sequence mutation into a valid trace by replaying through the generator.
///
/// Categorically, this is the Kleisli bind `μ: T²X → TX`. It takes a mutated choice sequence and replays it through the generator to produce a fresh `(sequence, tree)` pair. The property is NOT checked — only structural validity. The property check happens only on the downstream encoder's final output, at the composition boundary.
///
/// The ``LiftResult/liftReport`` describes the fidelity of the lift — how many coordinates were carried forward exactly (tier 1) versus substituted by the fallback tree (tier 2) or PRNG (tier 3). This is the grade of the Kleisli bind: the composite's grade is `min(grade(upstream), coverage(lift), grade(downstream))`.
///
/// See ``KleisliComposition`` for the composition that uses this lift.
public struct GeneratorLift<Output>: Sendable {
    /// The generator to replay through.
    let gen: ReflectiveGenerator<Output>

    /// How to resolve values at each choice point during the lift.
    let mode: LiftMode

    /// When true, the lifted tree stores all non-selected branch alternatives so that downstream branch simplification encoders can see the full pick site.
    let materializePicks: Bool

    /// Controls how values are resolved during the lift.
    public enum LiftMode: Sendable {
        /// Exact replay — rejects out-of-range values.
        case exact
        /// Guided replay with fallback tree for bound content.
        case guided(fallbackTree: ChoiceTree)
    }

    public init(gen: ReflectiveGenerator<Output>, mode: LiftMode, materializePicks: Bool = false) {
        self.gen = gen
        self.mode = mode
        self.materializePicks = materializePicks
    }

    /// Lifts the candidate sequence to produce a fresh tree and a lift report describing the fidelity of the cartesian lift.
    ///
    /// - Parameter seed: PRNG seed for guided mode. Different seeds produce different value assignments in the bound fibre. Ignored in exact mode.
    /// - Returns: `nil` if the lift rejected the candidate (out of range, structural mismatch).
    public func lift(_ candidate: ChoiceSequence, seed: UInt64 = 0) -> LiftResult<Output>? {
        let materializerMode: Materializer.Mode
        let fallbackTree: ChoiceTree?

        switch mode {
        case .exact:
            materializerMode = .exact
            fallbackTree = nil
        case let .guided(tree):
            materializerMode = .guided(seed: seed, fallbackTree: tree)
            fallbackTree = tree
        }

        switch Materializer.materialize(
            gen,
            prefix: candidate,
            mode: materializerMode,
            fallbackTree: fallbackTree,
            materializePicks: materializePicks
        ) {
        case let .success(value: value, tree: freshTree, decodingReport: report):
            let freshSequence = ChoiceSequence(freshTree)
            return LiftResult(
                value: value,
                sequence: freshSequence,
                tree: freshTree,
                liftReport: report
            )
        case .rejected, .failed:
            return nil
        }
    }
}

// MARK: - Lift Result

/// The output of a ``GeneratorLift``.
///
/// Contains the fresh sequence, tree, generated value, and a lift report describing how faithfully the lift carried the encoder's proposal into the new fibre.
public struct LiftResult<Output> {
    /// The generated value from replaying through the generator.
    public let value: Output

    /// The fresh choice sequence derived from the fresh tree.
    public let sequence: ChoiceSequence

    /// The fresh choice tree produced by the generator replay.
    public let tree: ChoiceTree

    /// Per-coordinate resolution tiers describing the fidelity of the lift.
    ///
    /// `nil` for exact mode (all coordinates are tier 1 by construction). For guided mode, describes how many coordinates were carried forward exactly (tier 1), substituted from the fallback tree (tier 2), or filled by PRNG (tier 3).
    public let liftReport: DecodingReport?
}
