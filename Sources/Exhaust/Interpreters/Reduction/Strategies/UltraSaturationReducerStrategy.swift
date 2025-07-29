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
        let next: UInt64 = switch direction {
        case .towardsLowerBound:
            value > .min ? value - 1 : .min
        case .towardsHigherBound:
            value < .max ? value + 1 : .max
        }
        return next == value ? nil : next
    }
    
    func next(for value: Int64) -> Int64? {
        let next: Int64 = switch direction {
        case .towardsLowerBound:
            value - 1
        case .towardsHigherBound:
            value + 1
        }
        return next == value ? nil : next
    }
    
    func next(for value: Double) -> Double? {
        let next: Double = switch direction {
        case .towardsLowerBound:
            value - 0.25
        case .towardsHigherBound:
            value + 0.25
        }
        return next == value ? nil : next
    }
    
    // MARK: - ChoiceSequenceReducerStrategy
    
    func next(for collection: [ChoiceTree].SubSequence) -> [[ChoiceTree].SubSequence] {
        // FIXME: This needs to do someething?
        []
    }
}
