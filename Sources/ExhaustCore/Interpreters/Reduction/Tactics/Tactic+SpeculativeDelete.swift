//
//  Tactic+SpeculativeDelete.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/3/2026.
//

/// Speculatively deletes spans and attempts repair via GuidedMaterializer fallback.
///
/// Delegates to ``ReducerStrategies.speculativeDeleteAndRepair`` and re-derives via
/// ``TacticReDerivation`` for bind-consistent output.
struct SpeculativeDeleteTactic: ShrinkTactic {
    let name = "speculativeDeleteAndRepair"
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
        let freeValueSpans = ChoiceSequence.extractFreeStandingValueSpans(from: sequence)
        let deletableSpans = freeValueSpans + targetSpans
        guard deletableSpans.isEmpty == false else { return nil }

        let counter = EvaluationCounter()
        guard let (newSequence, output) = try counter.wrap(property, body: { counted in
            try ReducerStrategies.speculativeDeleteAndRepair(
                gen, tree: tree, property: counted, sequence: sequence, spans: deletableSpans,
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
