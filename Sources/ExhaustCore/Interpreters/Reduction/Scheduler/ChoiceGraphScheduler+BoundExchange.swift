//
//  ChoiceGraphScheduler+BoundExchange.swift
//  Exhaust
//

// MARK: - Bound Exchange Encoder Construction

extension ChoiceGraphScheduler {
    /// Builds a ``GraphBoundExchangeEncoder`` whose lift materializes through `gen` in guided mode, so entries outside the ranges a candidate produces are re-resolved from the fallback tree rather than rejected.
    static func makeBoundExchangeEncoder(gen: AnyGenerator) -> EncoderDispatch {
        .boundExchange(GraphBoundExchangeEncoder(lift: { candidate, fallbackTree in
            guard case let .success(_, freshTree, _) = Materializer.materializeAny(
                gen,
                context: .init(
                    prefix: candidate,
                    mode: .guided(seed: 0, fallbackTree: fallbackTree),
                    fallbackTree: fallbackTree,
                    materializePicks: true
                )
            ) else {
                return nil
            }
            return freshTree
        }))
    }
}
