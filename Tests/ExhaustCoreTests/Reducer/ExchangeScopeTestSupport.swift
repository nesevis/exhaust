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
