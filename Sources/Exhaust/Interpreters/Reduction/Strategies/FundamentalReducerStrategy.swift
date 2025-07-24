//
//  FundamentalReducerStrategy.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/7/2025.
//

struct FundamentalReducerStrategy: ChoiceValueReducerStrategy, ChoiceSequenceReducerStrategy {
    let direction: ShrinkingDirection
    
    func values(for value: UInt64, in range: ClosedRange<UInt64>) -> [UInt64] {
        [0, 1, 2]
    }
    
    func values(for value: Int64, in range: ClosedRange<Int64>) -> [Int64] {
        [0, -1, 1, 2, -2]
    }
    
    func values(for value: Double, in range: ClosedRange<Double>) -> [Double] {
        [0, -0.1, -0.01, -0.001, -Double.ulpOfOne, -0.0001, Double.ulpOfOne, 0.001, 0.01, 0.1]
    }
    
    func values(for value: Character, in ranges: [ClosedRange<Character>]) -> [Character] {
        [" ", "a", "b", "c", "A", "B", "C", "0", "1", "2", "3", "\n", "\0"]
    }
    
    // MARK: - ChoiceSequenceReducerStrategy
    
    func values(for collection: some Collection, in lengthRange: ClosedRange<Int>) -> [any Collection] {
        [
            [],
            collection.prefix(1),
            collection.suffix(1)
        ]
    }
}
