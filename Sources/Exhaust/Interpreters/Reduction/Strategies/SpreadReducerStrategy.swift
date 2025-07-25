//
//  SpreadReducerStrategy.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/7/2025.
//


struct SpreadReducerStrategy: ChoiceValueReducerStrategy, ChoiceSequenceReducerStrategy {
    let direction: ShrinkingDirection
    
    func values(for value: UInt64, in range: ClosedRange<UInt64>) -> [UInt64] {
        range.equallySpacedExcludingBounds(count: 5)
    }
    
    func values(for value: Int64, in range: ClosedRange<Int64>) -> [Int64] {
        range.equallySpacedExcludingBounds(count: 5)
    }
    
    func values(for value: Double, in range: ClosedRange<Double>) -> [Double] {
        range.equallySpacedExcludingBounds(count: 5)
    }
    
    // MARK: - ChoiceSequenceReducerStrategy
    
    func values(for collection: some Collection, in lengthRange: ClosedRange<Int>) -> [any Collection] {
        guard collection.count > 0 else {
            return []
        }
        let chunks = lengthRange.equallySpacedExcludingBounds(count: collection.count / 10)
        guard chunks.isEmpty == false else {
            return []
        }
        let result = collection.evenlyChunked(in: chunks.count)
            .map(Array.init)
        return result
    }
}
