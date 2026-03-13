//
//  Tactic+PromoteBranches.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/3/2026.
//

/// Tries to promote each branch to a simpler (lower-index) alternative.
///
/// Delegates to ``ReducerStrategies.promoteBranches``. Branch tactics produce their own
/// tree directly, so no ``TacticReDerivation`` step is needed.
struct PromoteBranchesTactic: BranchShrinkTactic {
    let name = "promoteBranches"
    let applicability = TacticApplicability.branches

    func apply<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        context: TacticContext,
        property: (Output) -> Bool,
        rejectCache: inout ReducerCache,
    ) throws -> ShrinkResult<Output>? {
        guard let (newTree, newSequence, output) = try ReducerStrategies.promoteBranches(
            gen, tree: tree, property: property, sequence: sequence, rejectCache: &rejectCache, bindIndex: context.bindIndex
        ) else {
            return nil
        }
        return ShrinkResult(sequence: newSequence, tree: newTree, output: output, evaluations: 1)
    }
}
