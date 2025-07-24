//
//  BoundaryReducerStrategy.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/7/2025.
//

struct BoundaryReducerStrategy: ChoiceValueReducerStrategy, ChoiceSequenceReducerStrategy {
    let direction: ShrinkingDirection
    
    func values(for value: UInt64, in range: ClosedRange<UInt64>) -> [UInt64] {
        [.min, .max]
    }
    
    func values(for value: Int64, in range: ClosedRange<Int64>) -> [Int64] {
        [.min, .max]
    }
    
    func values(for value: Double, in range: ClosedRange<Double>) -> [Double] {
        // TODO: Rethink this
        return [
            Double.greatestFiniteMagnitude / 100000000,
            Double.greatestFiniteMagnitude / 10000000,
            Double.greatestFiniteMagnitude / 1000000,
            Double.greatestFiniteMagnitude / 100000,
            Double.greatestFiniteMagnitude / 10000,
            Double.greatestFiniteMagnitude / 1000,
            Double.greatestFiniteMagnitude / 100,
            Double.greatestFiniteMagnitude,
            -Double.greatestFiniteMagnitude,
            -Double.greatestFiniteMagnitude / 100,
            -Double.greatestFiniteMagnitude / 1000,
            -Double.greatestFiniteMagnitude / 10000,
            -Double.greatestFiniteMagnitude / 100000,
            -Double.greatestFiniteMagnitude / 1000000,
            -Double.greatestFiniteMagnitude / 10000000,
            -Double.greatestFiniteMagnitude / 100000000,
        ]
    }
    
    func values(for value: Character, in ranges: [ClosedRange<Character>]) -> [Character] {
        // TODO: Edge cases go here
        []
    }
    
    // MARK: - ChoiceSequenceReducerStrategy
    
    func values(for collection: some Collection, in lengthRange: ClosedRange<Int>) -> [any Collection] {
        [
            collection.dropFirst().dropLast(),
            collection.dropFirst(),
            collection.dropLast()
        ]
    }
}
