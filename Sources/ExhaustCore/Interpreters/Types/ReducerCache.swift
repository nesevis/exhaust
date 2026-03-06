//
//  ReducerCache.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/2/2026.
//

public struct ReducerCache {
    private var set = Set<ChoiceSequence>(minimumCapacity: 1000)
    /// Zobrist hash pre-filter for O(1) negative lookups in incremental paths.
    private var zobristHashes = Set<UInt64>(minimumCapacity: 1000)

    public init() {}

    public func contains(_ value: ChoiceSequence) -> Bool {
        set.contains(value)
    }

    /// O(1) for the common case (novel candidate = hash miss).
    /// Falls back to full Set.contains only on hash hit.
    public func contains(_ value: ChoiceSequence, zobristHash: UInt64) -> Bool {
        guard zobristHashes.contains(zobristHash) else { return false }
        return set.contains(value)
    }

    public mutating func insert(_ value: ChoiceSequence) {
        set.insert(value)
    }

    public mutating func insert(_ value: ChoiceSequence, zobristHash: UInt64) {
        set.insert(value)
        zobristHashes.insert(zobristHash)
    }
}
