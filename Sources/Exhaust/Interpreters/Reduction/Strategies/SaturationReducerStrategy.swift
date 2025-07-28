//
//  SaturationReducerStrategy.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/7/2025.
//

import Algorithms

struct SaturationReducerStrategy: LazyChoiceValueReducerStrategy, LazyChoiceSequenceReducerStrategy {
    let direction: ShrinkingDirection
    
    // We need a max here or it will just keep giving values
    func next(for value: UInt64) -> UInt64? {
        guard value > 0 else {
            return nil
        }
        return switch direction {
        case .towardsLowerBound:
            (value / 10) * 9
        case .towardsHigherBound:
            (value / 9) * 10
        }
    }
    
    func next(for value: Int64) -> Int64? {
        let newValue: Int64 = switch direction {
        case .towardsLowerBound where value < 0:
            (value * 10) / 9
        case .towardsLowerBound where value == 0:
            -1
        case .towardsLowerBound where value > 0:
            (value / 10) * 9
        case .towardsHigherBound where value < 0:
            (value / 10) * 9
        case .towardsHigherBound where value == 0:
            1
        case .towardsHigherBound where value > 0:
            (value * 10) / 9
        default:
            fatalError("Reducer error")
        }
        return newValue == value ? nil : newValue
    }
    
    func next(for value: Double) -> Double? {
        switch direction {
        case .towardsLowerBound where value < 0:
            (value * 10) / 9
        case .towardsLowerBound where value == 0:
            -1
        case .towardsLowerBound where value > 0:
            (value / 10) * 9
        case .towardsHigherBound where value < 0:
            (value / 10) * 9
        case .towardsHigherBound where value == 0:
            1
        case .towardsHigherBound where value > 0:
            (value * 10) / 9
        default:
            fatalError("Reducer error")
        }
    }
    
    // MARK: - LazyChoiceSequenceReducerStrategy
    
    func next(for collection: [ChoiceTree].SubSequence) -> [[ChoiceTree].SubSequence] {
        // FIXME: This should be improved
//        collection.evenlyChunked(in: max(collection.count / 10, 1))
        []
    }
}
