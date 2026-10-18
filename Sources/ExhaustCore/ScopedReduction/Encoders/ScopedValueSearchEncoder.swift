//
//  ScopedValueSearchEncoder.swift
//  Exhaust
//

// MARK: - Value Search Encoder

/// Drives integer leaves toward their semantic simplest values, one ``ScopedIntegerSearch`` per scope.
///
/// Value edits apply to the graph in place, so the search keeps going after an acceptance, working from the accepted candidate. An acceptance that reshapes a bound subtree still ends the pass.
enum ScopedValueSearchEncoder: ScopedEncoder {
    static let name: EncoderName = .valueSearch
    static let isPathChanging = false
    static let admissionOrder: ReductionOrder = .notLarger

    static func reducer(_ scope: ValueMinimizationScope, input: ScopedEncoderInput) -> ScopedReducer {
        .search(
            ScopedIntegerSearch(
                scope: scope,
                sequence: input.baseSequence,
                graph: input.graph,
                warmStarts: input.warmStartRecords,
                tuning: input.tuning
            ),
            configuration: .standard
        )
    }
}

// MARK: - Dispatch Requirements

extension ScopedValueSearchEncoder {
    static func gate(_ _: ValueMinimizationScope) -> ScopedDispatchGate {
        .open
    }

    static func convergenceInvalidatedByAcceptance(_: ValueMinimizationScope, in _: ChoiceGraph) -> ClosedRange<Int>? {
        nil
    }

    static func isValid(_: ValueMinimizationScope, in _: ChoiceGraph) -> Bool {
        true
    }
}
