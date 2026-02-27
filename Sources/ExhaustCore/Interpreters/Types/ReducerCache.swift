//
//  ReducerCache.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/2/2026.
//

struct ReducerCache {
    private var set = Set<ChoiceSequence>(minimumCapacity: 1000)

    func contains(_ value: ChoiceSequence) -> Bool {
        set.contains(value)
    }

    mutating func insert(_ value: ChoiceSequence) {
        set.insert(value)
    }
}
