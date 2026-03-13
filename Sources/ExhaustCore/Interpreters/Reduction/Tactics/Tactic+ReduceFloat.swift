//
//  Tactic+ReduceFloat.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/3/2026.
//

/// 4-stage float reduction pipeline (special values, truncation, integer domain, ratio).
///
/// Delegates to ``ReducerStrategies.reduceFloatValues`` and re-derives via
/// ``TacticReDerivation`` for bind-consistent output.
struct ReduceFloatTactic: ShrinkTactic {
    let name = "reduceFloat"
    let applicability = TacticApplicability.floatValues

    func apply<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        targetSpans: [ChoiceSpan],
        context: TacticContext,
        property: (Output) -> Bool,
        rejectCache: inout ReducerCache,
    ) throws -> ShrinkResult<Output>? {
        let counter = EvaluationCounter()
        guard let (newSequence, output) = try counter.wrap(property, body: { counted in
            try ReducerStrategies.reduceFloatValues(
                gen, tree: tree, property: counted,
                sequence: sequence, valueSpans: targetSpans,
                rejectCache: &rejectCache, bindIndex: context.bindIndex
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
