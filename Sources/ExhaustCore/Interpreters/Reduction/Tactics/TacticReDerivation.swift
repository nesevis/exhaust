//
//  TacticReDerivation.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/3/2026.
//

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
    ///   - originalTree: The current tree before mutation.
    ///   - bindIndex: The bind span index (`nil` for non-bind generators).
    ///   - property: The property under test — returns `true` for passing inputs.
    ///   - evaluations: Number of property evaluations already consumed by the strategy.
    /// - Returns: A ``ShrinkResult`` on success, or `nil` if re-derivation shows the mutation is not useful.
    static func resolve<Output>(
        strategySequence: ChoiceSequence,
        strategyOutput: Output,
        gen: ReflectiveGenerator<Output>,
        originalTree: ChoiceTree,
        bindIndex: BindSpanIndex?,
        property: (Output) -> Bool,
        evaluations: Int,
    ) -> ShrinkResult<Output>? {
        // Non-bind fast path: strategy result is consistent, no re-derivation needed.
        if bindIndex == nil || bindIndex?.isEmpty == true {
            return ShrinkResult(
                sequence: strategySequence,
                tree: originalTree,
                output: strategyOutput,
                evaluations: evaluations,
            )
        }

        // Bind path: re-derive via GuidedMaterializer.
        //
        // GuidedMaterializer skips bound entries in the prefix (cursor suspension), so re-derived
        // bound content comes from the fallback tree, not from the strategy's modifications.
        // When the strategy only modified bound values (e.g. zeroing at depth > 0), we must
        // preserve the strategy's sequence and output to retain those reductions. The re-derived
        // tree is still used for structural consistency.
        //
        // When the strategy modified inner values (depth 0), the bound generator may have changed.
        // Re-checking the property on the re-derived output catches mutations that are no longer
        // useful after re-derivation.
        let seed = strategySequence.zobristHash
        switch GuidedMaterializer.materialize(gen, prefix: strategySequence, seed: seed, fallbackTree: originalTree) {
        case let .success(reDerivedOutput, reDerivedSequence, reDerivedTree):
            // Re-check: if re-derived output passes the property, the mutation is not useful
            // (e.g. inner value change caused bound generator to produce a passing output).
            if property(reDerivedOutput) {
                return nil
            }
            // Both fail. Prefer the shortlex-smaller sequence to maximize reduction.
            // When the strategy zeroed bound values, strategySequence is smaller.
            // When the strategy modified inner values, reDerivedSequence has consistent bound content.
            if strategySequence.shortLexPrecedes(reDerivedSequence) {
                return ShrinkResult(
                    sequence: strategySequence,
                    tree: reDerivedTree,
                    output: strategyOutput,
                    evaluations: evaluations + 1,
                )
            }
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
