//
//  Tactic+DeleteSpans.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/3/2026.
//

/// Adaptively deletes container spans (sequence elements, boundaries).
///
/// Delegates to ``ReducerStrategies.adaptiveDeleteSpans`` and re-derives via
/// ``TacticReDerivation`` for bind-consistent output.
struct DeleteSpansTactic: ShrinkTactic {
    let name = "deleteSpans"
    let applicability = TacticApplicability.containers

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
            try ReducerStrategies.adaptiveDeleteSpans(
                gen, tree: tree, property: counted,
                sequence: sequence, spans: targetSpans,
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
