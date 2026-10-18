//
//  FloatSearchEncoder.swift
//  Exhaust
//

// MARK: - Float Search Encoder

/// Drives float leaves toward their semantic simplest values, one ``FloatSearch`` per scope.
///
/// Value edits apply to the graph in place, so the search keeps going after an acceptance, working from the accepted candidate. An acceptance that reshapes a bound subtree still ends the pass.
enum FloatSearchEncoder: ReductionEncoder {
    static let name: EncoderName = .floatSearch
    static let isPathChanging = false
    static let admissionOrder: ReductionOrder = .notLarger

    static func reduce(_ scope: FloatMinimizationScope, input: EncoderInput) -> Reduction {
        .search(
            FloatSearch(
                scope: scope,
                sequence: input.baseSequence,
                graph: input.graph
            ),
            configuration: .standard
        )
    }
}

// MARK: - Dispatch Requirements

extension FloatSearchEncoder {
    static func gate(_ _: FloatMinimizationScope) -> DispatchGate {
        .open
    }

    static func convergenceInvalidatedByAcceptance(_: FloatMinimizationScope, in _: ChoiceGraph) -> ClosedRange<Int>? {
        nil
    }

    static func isValid(_: FloatMinimizationScope, in _: ChoiceGraph) -> Bool {
        true
    }
}
