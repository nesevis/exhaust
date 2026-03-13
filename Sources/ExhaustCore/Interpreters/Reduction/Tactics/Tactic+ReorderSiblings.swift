//
//  Tactic+ReorderSiblings.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/3/2026.
//

/// Sorts sibling groups into shortlex order.
///
/// Delegates to ``ReducerStrategies.reorderSiblings`` and re-derives via
/// ``TacticReDerivation`` for bind-consistent output.
struct ReorderSiblingsTactic: SiblingGroupShrinkTactic {
    let name = "reorderSiblings"
    let applicability = TacticApplicability.ordering

    func apply<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        siblingGroups: [SiblingGroup],
        bindIndex: BindSpanIndex?,
        property: (Output) -> Bool,
        rejectCache: inout ReducerCache,
    ) throws -> ShrinkResult<Output>? {
        let counter = EvaluationCounter()
        guard let (newSequence, output) = try counter.wrap(property, body: { counted in
            try ReducerStrategies.reorderSiblings(
                gen, tree: tree, property: counted, sequence: sequence, siblingGroups: siblingGroups,
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
