//
//  Tactic+Redistribute.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/3/2026.
//

/// Redistributes numeric values between pairs (moves mass toward zero across siblings).
///
/// Delegates to ``ReducerStrategies.redistributeNumericPairs`` and re-derives via
/// ``TacticReDerivation`` for bind-consistent output.
struct RedistributeTactic: CrossStageShrinkTactic {
    let name = "redistribute"
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
        let valueCount = sequence.count(where: { $0.value != nil })
        guard valueCount >= 2, valueCount <= 16 else { return nil }
        let counter = EvaluationCounter()
        guard let (newSequence, output) = try counter.wrap(property, body: { counted in
            try ReducerStrategies.redistributeNumericPairs(
                gen, tree: tree, property: counted, sequence: sequence,
                rejectCache: &rejectCache, probeBudget: probeBudget,
                onBudgetExhausted: onBudgetExhausted,
                bindIndex: context.bindIndex,
                maximizeBoundValues: true
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
            maximizeBoundValues: true,
        )
    }
}
