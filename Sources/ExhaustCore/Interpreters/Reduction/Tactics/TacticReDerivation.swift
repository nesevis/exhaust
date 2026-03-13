//
//  TacticReDerivation.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/3/2026.
//

// MARK: - Tactic Evaluation

/// Depth-aware evaluation pipeline for purpose-built tactics.
///
/// Replaces both ``ReducerStrategies.materializeCandidate`` and ``TacticReDerivation.resolve()``
/// with a single function. At depth 0 with bind generators, ``GuidedMaterializer`` re-derives
/// bound content to maintain consistency. At depth > 0 or without binds, plain materialization
/// is used (no re-derivation needed).
enum TacticEvaluation {

    /// Evaluates a candidate mutation with depth-aware materialization.
    ///
    /// - Parameters:
    ///   - candidate: The proposed mutated sequence.
    ///   - gen: The reflective generator.
    ///   - tree: The current choice tree.
    ///   - context: Depth and bind context.
    ///   - strictness: Materialization strictness (`.normal` for structure-preserving mutations,
    ///     `.relaxed` for structural changes like deletion).
    ///   - originalSequence: The sequence before mutation, used to verify that re-derived
    ///     results are actual improvements (shortlex-smaller).
    ///   - property: The property under test — returns `true` for passing inputs.
    /// - Returns: A ``ShrinkResult`` on improvement (property fails on the materialized output),
    ///   or `nil` if the candidate doesn't produce a useful shrink.
    static func evaluate<Output>(
        candidate: ChoiceSequence,
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        context: TacticContext,
        strictness: Interpreters.Strictness,
        originalSequence: ChoiceSequence,
        property: (Output) -> Bool,
    ) throws -> ShrinkResult<Output>? {
        let bindIndex = context.bindIndex
        let needsReDerivation = context.depth == 0
            && bindIndex != nil
            && bindIndex?.isEmpty == false

        if needsReDerivation {
            // Depth 0 with binds: GuidedMaterializer re-derives the full triple.
            // The re-derived sequence is authoritative — bound content is consistent
            // with the new inner values. However, re-derivation can produce a sequence
            // that's longer than the original (bound content regenerated from PRNG/tree),
            // so we verify the result is an actual shortlex improvement.
            let seed = candidate.zobristHash
            switch GuidedMaterializer.materialize(gen, prefix: candidate, seed: seed, fallbackTree: context.fallbackTree ?? tree) {
            case let .success(reDerivedOutput, reDerivedSequence, reDerivedTree):
                guard reDerivedSequence.shortLexPrecedes(originalSequence) else { return nil }
                guard property(reDerivedOutput) == false else { return nil }
                return ShrinkResult(
                    sequence: reDerivedSequence,
                    tree: reDerivedTree,
                    output: reDerivedOutput,
                    evaluations: 1,
                )
            case .filterEncountered, .failed:
                return nil
            }
        } else if strictness == .relaxed {
            // Structural changes (deletion, boundary merging) invalidate the tree's
            // element scripts. GuidedMaterializer is sequence-driven — it rebuilds a
            // fresh tree from the generator, using the candidate as a prefix. The
            // returned (sequence, tree, output) triple is guaranteed consistent.
            let seed = candidate.zobristHash
            switch GuidedMaterializer.materialize(gen, prefix: candidate, seed: seed, fallbackTree: tree) {
            case let .success(reDerivedOutput, reDerivedSequence, reDerivedTree):
                guard reDerivedSequence.shortLexPrecedes(originalSequence) else { return nil }
                guard property(reDerivedOutput) == false else { return nil }
                return ShrinkResult(
                    sequence: reDerivedSequence,
                    tree: reDerivedTree,
                    output: reDerivedOutput,
                    evaluations: 1,
                )
            case .filterEncountered, .failed:
                return nil
            }
        } else {
            // Normal strictness, no binds: tree-driven materialization.
            guard let output = try Interpreters.materialize(
                gen, with: tree, using: candidate, strictness: strictness
            ) else {
                return nil
            }
            guard property(output) == false else { return nil }
            return ShrinkResult(
                sequence: candidate,
                tree: tree,
                output: output,
                evaluations: 1,
            )
        }
    }
}

// MARK: - Tactic Re-Derivation

/// Shared re-derivation logic for all non-branch tactics.
///
/// For bind-dependent generators, GuidedMaterializer can re-derive different bound content
/// from the same prefix, making the strategy's output inconsistent with the re-derived tree.
/// This helper uses the complete re-derived triple and re-checks the property for correctness.
///
/// For non-bind generators, the strategy's output is consistent — we skip the GuidedMaterializer
/// call entirely as a performance optimization.
enum TacticReDerivation {

    /// Resolves a strategy's (sequence, output) pair into a fully consistent ``ShrinkResult``.
    ///
    /// - Parameters:
    ///   - strategySequence: The mutated sequence produced by the strategy.
    ///   - strategyOutput: The output produced by the strategy (may be inconsistent for bind generators).
    ///   - gen: The reflective generator.
    ///   - originalSequence: The sequence before the strategy mutated it.
    ///   - originalTree: The current tree before mutation.
    ///   - context: Depth and bind context — used to determine whether GuidedMaterializer
    ///     re-derivation is needed.
    ///   - property: The property under test — returns `true` for passing inputs.
    ///   - evaluations: Number of property evaluations already consumed by the strategy.
    /// - Returns: A ``ShrinkResult`` on success, or `nil` if re-derivation shows the mutation is not useful.
    static func resolve<Output>(
        strategySequence: ChoiceSequence,
        strategyOutput: Output,
        gen: ReflectiveGenerator<Output>,
        originalSequence: ChoiceSequence,
        originalTree: ChoiceTree,
        context: TacticContext,
        property: (Output) -> Bool,
        evaluations: Int,
        maximizeBoundValues: Bool = false,
    ) -> ShrinkResult<Output>? {
        let bindIndex = context.bindIndex

        // Non-bind fast path: strategy result is consistent, no re-derivation needed.
        //
        // Depth > 0 fast path: tactic is operating on bound values directly. Inner values
        // are unchanged, so ranges are valid and the strategy's materialization is authoritative.
        // Re-derivation via GuidedMaterializer would replace the tactic's carefully chosen
        // bound values with PRNG-derived ones, undoing the reduction.
        if bindIndex == nil || bindIndex?.isEmpty == true || context.depth > 0 {
            return ShrinkResult(
                sequence: strategySequence,
                tree: originalTree,
                output: strategyOutput,
                evaluations: evaluations,
            )
        }

        // Cross-stage fast path (depth == -1): if only bound values were modified,
        // re-derivation is unnecessary. Inner values determine bound ranges, so unchanged
        // inner values mean the strategy's bound modifications are directly valid.
        // Re-derivation would replace carefully redistributed bound values with PRNG noise.
        if context.depth == -1, let bindIndex, bindIndex.isEmpty == false {
            let innerValuesChanged = bindIndex.regions.contains { region in
                region.innerRange.contains { idx in
                    strategySequence[idx].shortLexCompare(originalSequence[idx]) != .eq
                }
            }
            if innerValuesChanged == false {
                return ShrinkResult(
                    sequence: strategySequence,
                    tree: originalTree,
                    output: strategyOutput,
                    evaluations: evaluations,
                )
            }
        }

        // Bind path (depth 0, or depth -1 with inner changes): re-derive via GuidedMaterializer.
        //
        // The original tree serves as the tier-2 fallback: when inner values change and
        // bound ranges shift, GuidedMaterializer clamps old bound values to the new ranges
        // rather than randomizing them from PRNG. This preserves the reduction guarantee —
        // bound values stay as close to their last consistent state as the new ranges allow.
        // The shortlex guard below filters out regressions from any re-derivation drift.
        let seed = strategySequence.zobristHash
        switch GuidedMaterializer.materialize(gen, prefix: strategySequence, seed: seed, fallbackTree: originalTree, maximizeBoundValues: maximizeBoundValues) {
        case let .success(reDerivedOutput, reDerivedSequence, reDerivedTree):
            // Re-check: if re-derived output passes the property, the mutation is not useful
            // (e.g. inner value change caused bound generator to produce a passing output).
            if property(reDerivedOutput) {
                return nil
            }

            // Always use the re-derived triple for consistency. The re-derived sequence,
            // tree, and output all come from the same GuidedMaterializer call, so they
            // are guaranteed to agree. The shortlex guard prevents regressions when
            // re-derivation changes bound values (e.g. clamping to a smaller range or
            // restoring from the fallback tree).
            guard reDerivedSequence.shortLexPrecedes(originalSequence) else { return nil }
            return ShrinkResult(
                sequence: reDerivedSequence,
                tree: reDerivedTree,
                output: reDerivedOutput,
                evaluations: evaluations + 1,
            )
        case .filterEncountered, .failed:
            // Best-effort fallback: use strategy result with original tree.
            return ShrinkResult(
                sequence: strategySequence,
                tree: originalTree,
                output: strategyOutput,
                evaluations: evaluations,
            )
        }
    }

}

// MARK: - Evaluation Counter

/// Reference-type wrapper for counting property evaluations inside strategy calls.
///
/// Strategies receive the property as a closure. Wrapping it via ``wrap(_:body:)`` intercepts
/// each call to count evaluations without modifying the strategy's interface.
final class EvaluationCounter {
    private(set) var count: Int = 0

    /// Runs `body` with a counting wrapper around `property`.
    ///
    /// Uses `withoutActuallyEscaping` to bridge the non-escaping property into
    /// the strategy call without requiring `@escaping` at protocol boundaries.
    func wrap<Output, Result>(
        _ property: (Output) -> Bool,
        body: ((Output) -> Bool) throws -> Result,
    ) rethrows -> Result {
        try withoutActuallyEscaping(property) { escapableProperty in
            let counted: (Output) -> Bool = { [self] output in
                self.count += 1
                return escapableProperty(output)
            }
            return try body(counted)
        }
    }
}
