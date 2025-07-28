//
//  SpreadReducerStrategy.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/7/2025.
//


struct SpreadReducerStrategy: ChoiceValueReducerStrategy, ChoiceSequenceReducerStrategy, LazyChoiceValueReducerStrategy, LazyChoiceSequenceReducerStrategy {
    func values(for collection: some Collection, in lengthRange: ClosedRange<Int>) -> [any Collection] {
        []
    }
    
    let direction: ShrinkingDirection
    
    func next(for value: UInt64) -> UInt64? {
        nil
    }
    func values(for value: UInt64, in range: ClosedRange<UInt64>) -> [UInt64] {
        range.equallySpacedExcludingBounds(count: 5)
    }
    
    func next(for value: Int64) -> Int64? {
        nil
    }
    func values(for value: Int64, in range: ClosedRange<Int64>) -> [Int64] {
        range.equallySpacedExcludingBounds(count: 5)
    }
    
    func next(for value: Double) -> Double? {
        nil
    }
    func values(for value: Double, in range: ClosedRange<Double>) -> [Double] {
        range.equallySpacedExcludingBounds(count: 5)
    }
    
    // MARK: - ChoiceSequenceReducerStrategy
    
    func next(for collection: [ChoiceTree].SubSequence) -> [[ChoiceTree].SubSequence] {
        // FIXME: This needs to do something
        []
    }
}
