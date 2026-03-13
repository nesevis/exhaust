//
//  Tactic+ReduceInTandem.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/3/2026.
//

/// Reduces sibling values in tandem (all siblings move toward zero together).
///
/// Delegates to ``ReducerStrategies.reduceValuesInTandem`` and re-derives via
/// ``TacticReDerivation`` for bind-consistent output.
struct ReduceInTandemTactic: CrossStageShrinkTactic {
    let name = "reduceInTandem"
    let probeBudget: Int
    var onBudgetExhausted: ((String) -> Void)?

    func apply<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        siblingGroups: [SiblingGroup],
        allValueSpans: [ChoiceSpan],
        context: TacticContext,
        property: (Output) -> Bool,
        rejectCache: inout ReducerCache,
    ) throws -> ShrinkResult<Output>? {
        guard siblingGroups.isEmpty == false else { return nil }
        let counter = EvaluationCounter()
        guard let (newSequence, output) = try counter.wrap(property, body: { counted in
            try ReducerStrategies.reduceValuesInTandem(
                gen, tree: tree, property: counted, sequence: sequence, siblingGroups: siblingGroups,
                rejectCache: &rejectCache, probeBudget: probeBudget,
                onBudgetExhausted: onBudgetExhausted,
                bindIndex: context.bindIndex
            )
        }) else {
            return nil
        }
        return TacticReDerivation.resolve(
            strategySequence: newSequence,
            strategyOutput: output,
            gen: gen,
            originalSequence: sequence,
            originalTree: tree,
            context: context,
            property: property,
            evaluations: counter.count,
        )
    }
}
