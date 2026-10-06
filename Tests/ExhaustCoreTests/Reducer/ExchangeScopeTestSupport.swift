//
//  ExchangeScopeTestSupport.swift
//  Exhaust
//

@testable import ExhaustCore

extension [ExchangeScope] {
    /// The tandem scope among these scopes. ``ExchangeQuery/build(graph:)`` emits at most one.
    var tandemScope: TandemScope? {
        for scope in self {
            if case let .tandem(tandemScope) = scope {
                return tandemScope
            }
        }
        return nil
    }
}

extension RedistributionScope {
    /// Materializes the pair stream only for test assertions and eager reference paths; production consumers use ``pairCursor()``.
    var pairs: [RedistributionPair] {
        var cursor = pairCursor()
        var result: [RedistributionPair] = []
        result.reserveCapacity(pairCount)
        while let pair = cursor.next(lastAccepted: false) {
            result.append(pair)
        }
        return result
    }
}
