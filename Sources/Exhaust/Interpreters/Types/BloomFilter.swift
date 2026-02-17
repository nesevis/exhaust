//
//  BloomFilter.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/2/2026.
//

/// A Bloom filter with k=3 hash functions, used by the reducer to minimise oracle and materialize calls.
/// Uses double hashing: index_i = (h1 + i * h2) % size, for i in 0..<3.
struct BloomFilter {
    private static let size = 32768
    private static let k = 3
    private var bits = ContiguousArray(repeating: false, count: BloomFilter.size)

    func contains(_ value: ChoiceSequence) -> Bool {
        let (h1, h2) = value.bloomHashes
        for i in 0 ..< Self.k {
            let index = abs((h1 &+ i &* h2) % Self.size)
            if !bits[index] { return false }
        }
        return true
    }

    mutating func insert(_ value: ChoiceSequence) {
        let (h1, h2) = value.bloomHashes
        for i in 0 ..< Self.k {
            let index = abs((h1 &+ i &* h2) % Self.size)
            bits[index] = true
        }
    }

    mutating func clear() {
        bits = .init(repeating: false, count: Self.size)
    }
}
