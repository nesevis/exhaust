//
//  SaturationReducerStrategy.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/7/2025.
//

import Algorithms

struct SaturationReducerStrategy: ChoiceValueReducerStrategy, ChoiceSequenceReducerStrategy, LazyChoiceValueReducerStrategy, LazyChoiceSequenceReducerStrategy {
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
    
    func values(for value: UInt64, in range: ClosedRange<UInt64>) -> [UInt64] {
        let max = 50
        var count = 0
        var values = [UInt64]()
        switch direction {
        case .towardsLowerBound:
            var candidate = (value / 10) * 9
            while count < max, candidate > range.lowerBound {
                count += 1
                values.append(candidate)
                candidate = (candidate / 10) * 9
            }
        case .towardsHigherBound:
            var candidate = (value * 10) / 9
            while count < max, candidate < range.upperBound {
                count += 1
                values.append(candidate)
                candidate = (candidate * 10) / 9
            }
        }
        return values
    }
    
    func next(for value: Int64) -> Int64? {
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
    
    func values(for value: Int64, in range: ClosedRange<Int64>) -> [Int64] {
        guard value != 0 else {
            print("Called \(Self.self) with 0 value; returning no valid shrinks?!")
            return []
        }
        let max = 50
        var count = 0
        var values = [Int64]()
        switch direction {
        case .towardsLowerBound:
            var candidate = (value / 10) * 9
            while count < max, candidate > range.lowerBound {
                count += 1
                values.append(candidate)
                candidate = (candidate / 10) * 9
            }
        case .towardsHigherBound:
            var candidate = value < 0 ? (value / 10) * 9 : (value * 10) / 9
            while count < max, candidate < range.upperBound {
                count += 1
                values.append(candidate)
                candidate = candidate < 0 ? (candidate / 10) * 9 : (candidate * 10) / 9
            }
        }
        return values
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
    
    func values(for value: Double, in range: ClosedRange<Double>) -> [Double] {
        guard value != 0 else {
            print("Called \(Self.self) with 0 value; returning no valid shrinks?!")
            return []
        }
        let max = 50
        var count = 0
        var values = [Double]()
        switch direction {
        case .towardsLowerBound:
            var candidate = (value / 10) * 9
            while count < max, candidate > range.lowerBound {
                count += 1
                values.append(candidate)
                candidate = (candidate / 10) * 9
            }
        case .towardsHigherBound:
            var candidate = (value * 10) / 9
            while count < max, candidate < range.upperBound {
                count += 1
                values.append(candidate)
                candidate = (candidate * 10) / 9
            }
        }
        return values
    }
    
    // MARK: - ChoiceSequenceReducerStrategy
    
    func next(for collection: [ChoiceTree].SubSequence) -> [[ChoiceTree].SubSequence] {
        // FIXME: This should be improved
//        collection.evenlyChunked(in: max(collection.count / 10, 1))
        []
    }
    
    func values(for collection: some Collection, in lengthRange: ClosedRange<Int>) -> [any Collection] {
        let count = collection.underestimatedCount
        guard count > 1 else {
            print("Called \(Self.self) with \(count) value(s); returning no valid shrinks?!")
            return []
        }
        
        let chunks = collection.evenlyChunked(in: max(count / 10, 1))
        
        return chunks
            .filter { lengthRange.contains($0.count) }
    }
}
