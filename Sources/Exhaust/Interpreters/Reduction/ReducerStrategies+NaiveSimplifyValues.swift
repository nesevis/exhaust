//
//  ReducerStrategies+NaiveSimplifyValues.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/2/2026.
//

extension ReducerStrategies {
    /// Pass 0: Try setting values to their semantically simplest form.
    ///
    /// - Complexity: O(*n* + *M*), where *n* is the number of value spans and *M* is the cost
    ///   of a single oracle call (materialize + property evaluation). Always makes at most one oracle call.
    static func naiveSimplifyValues<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        valueSpans: [ChoiceSpan],
        rejectCache: inout ReducerCache,
    ) throws -> (ChoiceSequence, Output)? {
        var updatedSequence = sequence
        for span in valueSpans {
            let seqIdx = span.range.lowerBound
            guard case let .value(v) = sequence[seqIdx] else { continue }
            let simplified = v.choice.semanticSimplest
            guard simplified != v.choice, simplified.fits(in: v.validRanges) else { continue }
            updatedSequence[seqIdx] = .value(.init(choice: simplified, validRanges: v.validRanges))
        }
        guard updatedSequence != sequence,
              rejectCache.contains(updatedSequence) == false
        else {
            return nil
        }
        rejectCache.insert(updatedSequence)
        if let output = try? Interpreters.materialize(gen, with: tree, using: updatedSequence), property(output) == false {
            return (updatedSequence, output)
        }
        return nil
    }
}
