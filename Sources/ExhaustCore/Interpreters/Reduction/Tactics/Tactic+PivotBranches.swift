//
//  Tactic+PivotBranches.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/3/2026.
//

/// Pivots each branch by trying the complement alternative.
///
/// Delegates to ``ReducerStrategies.pivotBranches``. Branch tactics produce their own
/// tree directly, so no ``TacticReDerivation`` step is needed.
struct PivotBranchesTactic: BranchShrinkTactic {
    let name = "pivotBranches"
    let applicability = TacticApplicability.branches

    func apply<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        bindIndex: BindSpanIndex?,
        property: (Output) -> Bool,
        rejectCache: inout ReducerCache,
    ) throws -> ShrinkResult<Output>? {
        guard let (newTree, newSequence, output) = try ReducerStrategies.pivotBranches(
            gen, tree: tree, property: property, sequence: sequence, rejectCache: &rejectCache, bindIndex: bindIndex
        ) else {
            return nil
        }
        return ShrinkResult(sequence: newSequence, tree: newTree, output: output, evaluations: 1)
    }
}
