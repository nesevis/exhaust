//
//  BinaryReducerStrategy.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/7/2025.
//


struct BinaryReducerStrategy: ChoiceValueReducerStrategy, ChoiceSequenceReducerStrategy, LazyChoiceValueReducerStrategy, LazyChoiceSequenceReducerStrategy {
    let direction: ShrinkingDirection
    
    func next(for value: UInt64) -> UInt64? {
        switch direction {
        case .towardsLowerBound:
            value / 2
        case .towardsHigherBound:
            value &* 2
        }
    }
    
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
    
    func next(for value: Int64) -> Int64? {
        switch direction {
        case .towardsLowerBound where value < 0:
            value * 2
        case .towardsLowerBound where value == 0:
            -1
        case .towardsLowerBound where value > 0:
            value - (value / 2)
        case .towardsHigherBound where value < 0:
            value / 2
        case .towardsHigherBound where value == 0:
            1
        case .towardsHigherBound where value > 0:
            value * 2
        default:
            fatalError("Reducer error")
        }
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
    static let reductionStrategy: [(threshold: Double, factor: Double)] = [
        (1e250, 1e100),  // Extreme values: divide by 10^100
        (1e150, 1e50),   // Very large: divide by 10^50
        (1e75,  1e25),   // Large: divide by 10^25
        (1e30,  1e15),   // Moderate large: divide by 10^15
        (1e15,  1e10),   // Billions range: divide by 10^10
        (1e10,  1e6),    // Millions range: divide by 10^6
        (1e6,   1e3),    // Thousands range: divide by 1000
        (1e3,   100),    // Hundreds range: divide by 100
        (100,   10),     // Tens range: divide by 10
        (10,    2),      // Single digits: divide by 2
    ]
    
    func next(for value: Double) -> Double? {
        guard value.isFinite else {
            return nil
        }
        let strategicDivisor = Self.reductionStrategy.first(where: { value > $0.threshold })?.factor ?? 2
        switch direction {
        case .towardsLowerBound where value < 0:
            return value * strategicDivisor
        case .towardsLowerBound where value == 0:
            return -1
        case .towardsLowerBound where value > 0:
            return value / strategicDivisor
        case .towardsHigherBound where value < 0:
            return value / strategicDivisor
        case .towardsHigherBound where value == 0:
            return 1
        case .towardsHigherBound where value > 0:
            return value * strategicDivisor
        default:
            fatalError("Reducer error")
        }
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
    
    func next(for collection: [ChoiceTree].SubSequence) -> [[ChoiceTree].SubSequence] {
        let count = collection.count
        let halved = count / 2
        var subsequences = [[ChoiceTree].SubSequence]()
        subsequences.append(collection.prefix(halved))
        subsequences.append(collection.suffix(count - halved))
        return subsequences
    }
    
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
