//
//  UltraSaturationReducerStrategy.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/7/2025.
//

import Algorithms

struct UltraSaturationReducerStrategy: ChoiceValueReducerStrategy, ChoiceSequenceReducerStrategy, LazyChoiceValueReducerStrategy, LazyChoiceSequenceReducerStrategy {
    let direction: ShrinkingDirection
    
    func next(for value: UInt64) -> UInt64? {
        switch direction {
        case .towardsLowerBound:
            value > .min ? value - 1 : nil
        case .towardsHigherBound:
            value < .max ? value + 1 : nil
        }
    }
    func values(for value: UInt64, in range: ClosedRange<UInt64>) -> [UInt64] {
        var values = [UInt64]()
        let limit = 50
        var count = 0
        switch direction {
        case .towardsLowerBound:
            guard value > 0 else {
                return []
            }
            var candidate = value - 1
            while count < limit, candidate > range.lowerBound {
                values.append(candidate)
                candidate -= 1
                count += 1
            }
        case .towardsHigherBound:
            var candidate = value + 1
            while count < limit, candidate < range.upperBound {
                values.append(candidate)
                candidate += 1
                count += 1
            }
        }
        return values
    }
    
    func next(for value: Int64) -> Int64? {
        switch direction {
        case .towardsLowerBound:
            value - 1
        case .towardsHigherBound:
            value + 1
        }
    }
    
    func values(for value: Int64, in range: ClosedRange<Int64>) -> [Int64] {
        var values = [Int64]()
        let limit = 50
        var count = 0
        switch direction {
        case .towardsLowerBound:
            var candidate = value - 1
            while count < limit, candidate > range.lowerBound {
                values.append(candidate)
                candidate -= 1
                count += 1
            }
        case .towardsHigherBound:
            var candidate = value + 1
            while count < limit, candidate < range.upperBound {
                values.append(candidate)
                candidate += 1
                count += 1
            }
        }
        return values
    }
    
    func next(for value: Double) -> Double? {
        switch direction {
        case .towardsLowerBound:
            value - 0.1
        case .towardsHigherBound:
            value + 0.1
        }
    }
    
    func values(for value: Double, in range: ClosedRange<Double>) -> [Double] {
        var values = [Double]()
        let limit = 50
        var count = 0
        switch direction {
        case .towardsLowerBound:
            var candidate = value - 0.1
            while count < limit, candidate > range.lowerBound {
                values.append(candidate)
                candidate -= 0.1
                count += 1
            }
        case .towardsHigherBound:
            var candidate = value + 0.1
            while count < limit, candidate < range.upperBound {
                values.append(candidate)
                candidate += 0.1
                count += 1
            }
        }
        return values
    }
    
    // MARK: - ChoiceSequenceReducerStrategy
    
    func next(for collection: [ChoiceTree].SubSequence) -> [[ChoiceTree].SubSequence] {
        // FIXME: This needs to do someething
        []
    }
    
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
