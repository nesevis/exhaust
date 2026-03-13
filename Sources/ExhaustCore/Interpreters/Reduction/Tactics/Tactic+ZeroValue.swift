//
//  Tactic+ZeroValue.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/3/2026.
//

/// Tries to set each numeric value to zero (shortlex minimum).
///
/// Delegates to ``ReducerStrategies.naiveSimplifyValues`` and re-derives via
/// ``TacticReDerivation`` for bind-consistent output.
struct ZeroValueTactic: ShrinkTactic {
    let name = "zeroValue"
    let applicability = TacticApplicability.numericValues

    func apply<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        targetSpans: [ChoiceSpan],
        bindIndex: BindSpanIndex?,
        property: (Output) -> Bool,
        rejectCache: inout ReducerCache,
    ) throws -> ShrinkResult<Output>? {
        let counter = EvaluationCounter()
        guard let (newSequence, output) = try counter.wrap(property, body: { counted in
            try ReducerStrategies.naiveSimplifyValues(
                gen, tree: tree, property: counted,
                sequence: sequence, valueSpans: targetSpans,
                rejectCache: &rejectCache, bindIndex: bindIndex
            )
        }) else {
            return nil
        }
        return TacticReDerivation.resolve(
            strategySequence: newSequence,
            strategyOutput: output,
            gen: gen,
            originalTree: tree,
            bindIndex: bindIndex,
            property: property,
            evaluations: counter.count,
        )
    }
}
