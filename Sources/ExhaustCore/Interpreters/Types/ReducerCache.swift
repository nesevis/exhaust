//
//  ReducerCache.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/2/2026.
//

@_spi(ExhaustInternal) public struct ReducerCache {
    private var set = Set<ChoiceSequence>(minimumCapacity: 1000)

    @_spi(ExhaustInternal) public init() {}

    @_spi(ExhaustInternal) public func contains(_ value: ChoiceSequence) -> Bool {
        set.contains(value)
    }

    @_spi(ExhaustInternal) public mutating func insert(_ value: ChoiceSequence) {
        set.insert(value)
    }
}
