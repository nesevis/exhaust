//
//  ReducerStrategies+NaiveSimplifyValues.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/2/2026.
//

extension ReducerStrategies {
    /// Pass 0: Try setting values to their semantically simplest form.
    ///
    /// - Complexity: O(*n* + *M*), where *n* is the number of value spans and *M* is the cost of a single property invocation (materialize + property evaluation). Always makes at most one property invocation.
    static func naiveSimplifyValues<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        valueSpans: [ChoiceSpan],
        rejectCache: inout ReducerCache,
        bindIndex: BindSpanIndex? = nil,
    ) throws -> (ChoiceSequence, Output)? {
        var updatedSequence = sequence
        for span in valueSpans {
            let seqIdx = span.range.lowerBound
            guard case let .value(v) = sequence[seqIdx] else { continue }
            let simplified = v.choice.semanticSimplest
            guard simplified != v.choice, !v.isRangeExplicit || simplified.fits(in: v.validRange) else { continue }
            updatedSequence[seqIdx] = .value(.init(choice: simplified, validRange: v.validRange, isRangeExplicit: v.isRangeExplicit))
        }
        guard updatedSequence != sequence, rejectCache.contains(updatedSequence) == false else {
            return nil
        }
        let modifiedIndices = valueSpans.compactMap { span -> Int? in
            let seqIdx = span.range.lowerBound
            guard case let .value(v) = sequence[seqIdx] else { return nil }
            let simplified = v.choice.semanticSimplest
            guard simplified != v.choice, !v.isRangeExplicit || simplified.fits(in: v.validRange) else { return nil }
            return seqIdx
        }
        let output = try? ReducerStrategies.materializeCandidate(gen, tree: tree, candidate: updatedSequence, bindIndex: bindIndex, mutatedIndices: modifiedIndices)
        if let output, property(output) == false {
            return (updatedSequence, output)
        }
        rejectCache.insert(updatedSequence)
        return nil
    }
}
