//
//  ScopedRedistributionEncoder.swift
//  Exhaust
//

// MARK: - Redistribution Encoder

/// Moves magnitude between type-compatible leaf pairs, preserving their sum, so that later searches can reduce the sequence further.
///
/// Value edits apply to the graph in place, so the search keeps going after an acceptance, working from the accepted candidate.
enum ScopedRedistributionEncoder: ScopedEncoder {
    static let name: EncoderName = .redistribution
    static let isValueDependent = true
    static let isPathChanging = false
    static let admissionOrder: ReductionOrder = .notLarger

    static func reducer(_ scope: RedistributionScope, input: ScopedEncoderInput) -> ScopedReducer {
        .search(
            ScopedRedistributionSearch(
                scope: scope,
                sequence: input.baseSequence,
                graph: input.graph,
                tuning: input.tuning
            ),
            configuration: .standard
        )
    }
}

// MARK: - Dispatch Requirements

extension ScopedRedistributionEncoder {
    static func gate(_ _: RedistributionScope) -> ScopedDispatchGate {
        .open
    }

    static func convergenceInvalidatedByAcceptance(_: RedistributionScope, in _: ChoiceGraph) -> ClosedRange<Int>? {
        nil
    }

    static func isValid(_: RedistributionScope, in _: ChoiceGraph) -> Bool {
        true
    }
}
