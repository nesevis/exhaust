//
//  Tactic+DeleteAlignedWindows.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/3/2026.
//

/// Deletes aligned windows of sibling elements (beam-search subset selection).
///
/// Delegates to ``ReducerStrategies.deleteAlignedSiblingWindows`` and re-derives via
/// ``TacticReDerivation`` for bind-consistent output.
struct DeleteAlignedWindowsTactic: ShrinkTactic {
    let name = "deleteAlignedWindows"
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
        // Aligned window deletion needs sibling groups, not raw spans
        let siblingGroups = ChoiceSequence.extractSiblingGroups(from: sequence)
        guard siblingGroups.isEmpty == false else { return nil }

        let counter = EvaluationCounter()
        guard let (newSequence, output) = try counter.wrap(property, body: { counted in
            try ReducerStrategies.deleteAlignedSiblingWindows(
                gen, tree: tree, property: counted, sequence: sequence, siblingGroups: siblingGroups,
                rejectCache: &rejectCache,
                probeBudget: 400,
                subsetBeamSearchTuning: .fast,
                bindIndex: bindIndex
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
