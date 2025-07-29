//
//  BinaryReducerStrategy.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/7/2025.
//


struct BinaryReducerStrategy: LazyChoiceValueReducerStrategy, LazyChoiceSequenceReducerStrategy {
    let direction: ShrinkingDirection
    
    func next(for value: UInt64) -> UInt64? {
        let next = switch direction {
        case .towardsLowerBound:
            value / 2
        case .towardsHigherBound:
            value &* 2
        }
        return next == value ? nil : next
    }
    
    // TODO: This can be a lot more aggressive along the lines of the Double implementation
    func next(for value: Int64) -> Int64? {
        let next: Int64 = switch direction {
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
        return next == value ? nil : next
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
        let next: Double = switch direction {
        case .towardsLowerBound where value < 0:
            value * strategicDivisor
        case .towardsLowerBound where value == 0:
            -1
        case .towardsLowerBound where value > 0:
            value / strategicDivisor
        case .towardsHigherBound where value < 0:
            value / strategicDivisor
        case .towardsHigherBound where value == 0:
            1
        case .towardsHigherBound where value > 0:
            value * strategicDivisor
        default:
            fatalError("Reducer error")
        }
        return next == value ? nil : next
    }
    
    // MARK: - LazyChoiceSequenceReducerStrategy
    
    func next(for collection: [ChoiceTree].SubSequence) -> [[ChoiceTree].SubSequence] {
        guard collection.count > 1 else {
            return []
        }
        let count = collection.count
        let halved = count / 2
        var subsequences = [[ChoiceTree].SubSequence]()
        subsequences.append(collection.prefix(halved))
        subsequences.append(collection.suffix(count - halved))
        return subsequences
    }
}
