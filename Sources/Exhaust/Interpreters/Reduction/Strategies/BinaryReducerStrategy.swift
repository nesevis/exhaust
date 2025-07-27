//
//  BinaryReducerStrategy.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/7/2025.
//


struct BinaryReducerStrategy: ChoiceValueReducerStrategy, ChoiceSequenceReducerStrategy {
    let direction: ShrinkingDirection
    
    func values(for value: UInt64, in range: ClosedRange<UInt64>) -> [UInt64] {
        let limit = 50
        var count = 0
        var values = [UInt64]()
        switch direction {
        case .towardsLowerBound:
            var candidate = value / 2
            while count < limit, candidate > range.lowerBound {
                values.append(candidate)
                candidate /= 2
                count += 1
            }
        case .towardsHigherBound:
            var candidate = value * 2
            while count < limit, candidate < range.upperBound {
                values.append(candidate)
                candidate *= 2
                count += 1
            }
        }
        return values
    }
    
    func values(for value: Int64, in range: ClosedRange<Int64>) -> [Int64] {
        let limit = 50
        var count = 0
        var values = [Int64]()
        switch direction {
        case .towardsLowerBound:
            var candidate = value / 2
            while count < limit, candidate > range.lowerBound {
                values.append(candidate)
                candidate /= 2
                count += 1
            }
        case .towardsHigherBound:
            // FIXME: Fundamental error here is that multiplying -2 * 3 is -6, so we need to check whether the number is negative or not
            var candidate = value < 0 ? value / 2 : value * 2
            while count < limit, candidate < range.upperBound {
                values.append(candidate)
//                if range.upperBound - abs(candidate) < abs(candidate) {
//                    break
//                }
                if candidate < 0 {
                    candidate /= 2
                } else {
                    candidate *= 2
                }
                count += 1
            }
        }
        return values
    }
    
    func values(for value: Double, in range: ClosedRange<Double>) -> [Double] {
        let limit = 50
        var count = 0
        var values = [Double]()
        switch direction {
        case .towardsLowerBound:
            var candidate = value / 2
            while count < limit, candidate > range.lowerBound {
                values.append(candidate)
                candidate /= 2
                count += 1
            }
        case .towardsHigherBound:
            var candidate = value * 2
            while count < limit, candidate < range.upperBound {
                values.append(candidate)
                candidate *= 2
                count += 1
            }
        }
        return values
    }
    
    // MARK: - ChoiceSequenceReducerStrategy
    
    func values(for collection: some Collection, in lengthRange: ClosedRange<Int>) -> [any Collection] {
        let count = collection.count
        let halved = count / 2
        var subsequences = [any Collection]()
        if lengthRange.contains(halved) {
            subsequences.append(collection.prefix(halved))
        }
        if lengthRange.contains(count - halved) {
            subsequences.append(collection.suffix(count - halved))
        }
        return subsequences
    }
}
