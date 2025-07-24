//
//  SaturationReducerStrategy.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/7/2025.
//

import Algorithms

struct SaturationReducerStrategy: ChoiceValueReducerStrategy, ChoiceSequenceReducerStrategy {
    let direction: ShrinkingDirection
    
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
            var candidate = (value * 10) / 9
            while count < max, candidate < range.upperBound {
                count += 1
                values.append(candidate)
                candidate = (candidate * 10) / 9
            }
        }
        return values
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
    
    func values(for collection: some Collection, in lengthRange: ClosedRange<Int>) -> [any Collection] {
        let count = collection.underestimatedCount
        guard count > 1 else {
            print("Called \(Self.self) with \(count) value(s); returning no valid shrinks?!")
            return []
        }
        
        let chunks = collection.evenlyChunked(in: count / 10)
        
        return chunks
            .filter { lengthRange.contains($0.count) }
    }
}
