//
//  UltraSaturationReducerStrategy.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/7/2025.
//

import Algorithms

struct UltraSaturationReducerStrategy: LazyChoiceValueReducerStrategy, LazyChoiceSequenceReducerStrategy {
    let direction: ShrinkingDirection
    
    func next(for value: UInt64) -> UInt64? {
        switch direction {
        case .towardsLowerBound:
            value > .min ? value - 1 : nil
        case .towardsHigherBound:
            value < .max ? value + 1 : nil
        }
    }
    
    func next(for value: Int64) -> Int64? {
        switch direction {
        case .towardsLowerBound:
            value - 1
        case .towardsHigherBound:
            value + 1
        }
    }
    
    func next(for value: Double) -> Double? {
        switch direction {
        case .towardsLowerBound:
            value - 0.1
        case .towardsHigherBound:
            value + 0.1
        }
    }
    
    // MARK: - ChoiceSequenceReducerStrategy
    
    func next(for collection: [ChoiceTree].SubSequence) -> [[ChoiceTree].SubSequence] {
        // FIXME: This needs to do someething?
        []
    }
}
