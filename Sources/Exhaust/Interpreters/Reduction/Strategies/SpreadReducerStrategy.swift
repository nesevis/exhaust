//
//  SpreadReducerStrategy.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/7/2025.
//


struct SpreadReducerStrategy: LazyChoiceValueReducerStrategy, LazyChoiceSequenceReducerStrategy {
    let direction: ShrinkingDirection
    
    func next(for value: UInt64) -> UInt64? {
        nil
    }
    
    func next(for value: Int64) -> Int64? {
        // range.equallySpacedExcludingBounds(count: 5)
        nil
    }
    
    func next(for value: Double) -> Double? {
        nil
    }
    
    // MARK: - Lazy ChoiceSequenceReducerStrategy
    
    func next(for collection: [ChoiceTree].SubSequence) -> [[ChoiceTree].SubSequence] {
        // FIXME: This needs to do something
        []
    }
}
