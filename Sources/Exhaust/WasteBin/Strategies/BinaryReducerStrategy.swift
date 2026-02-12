////
////  BinaryReducerStrategy.swift
////  Exhaust
////
////  Created by Chris Kolbu on 24/7/2025.
////
//
//
//struct BinaryReducerStrategy: LazyChoiceValueReducerStrategy, LazyChoiceSequenceReducerStrategy {
//    let direction: ShrinkingDirection
//    
//    func next(for value: UInt64) -> UInt64? {
//        let strategicDivisor = Self.uintReductionStrategy.first(where: { value > $0.threshold })?.factor ?? 2
//        let next = switch direction {
//        case .towardsLowerBound:
//            value / strategicDivisor
//        case .towardsHigherBound:
//            value &* strategicDivisor
//        }
//        return next == value ? nil : next
//    }
//    
//    func next(for value: Int64) -> Int64? {
//        let absoluteValue = UInt64(abs(value))
//        let strategicDivisor = Self.intReductionStrategy.first(where: { absoluteValue > $0.threshold })?.factor ?? 2
//        let next: Int64 = switch direction {
//        case .towardsLowerBound where value < 0:
//            value * Int64(strategicDivisor)
//        case .towardsLowerBound where value == 0:
//            -1
//        case .towardsLowerBound where value > 0:
//            value / Int64(strategicDivisor)
//        case .towardsHigherBound where value < 0:
//            value / Int64(strategicDivisor)
//        case .towardsHigherBound where value == 0:
//            1
//        case .towardsHigherBound where value > 0:
//            value * Int64(strategicDivisor)
//        default:
//            fatalError("Reducer error")
//        }
//        return next == value ? nil : next
//    }
//
//    static let doubleReductionStrategy: [(threshold: Double, factor: Double)] = [
//        (1e250, 1e100),  // Extreme values: divide by 10^100
//        (1e150, 1e50),   // Very large: divide by 10^50
//        (1e75,  1e25),   // Large: divide by 10^25
//        (1e30,  1e15),   // Moderate large: divide by 10^15
//        (1e15,  1e10),   // Billions range: divide by 10^10
//        (1e10,  1e6),    // Millions range: divide by 10^6
//        (1e6,   1e3),    // Thousands range: divide by 1000
//        (1e3,   100),    // Hundreds range: divide by 100
//        (100,   10),     // Tens range: divide by 10
//        (10,    2),      // Single digits: divide by 2
//    ]
//    
//    static let uintReductionStrategy: [(threshold: UInt64, factor: UInt64)] = [
//        (UInt64.max / 2, 1_000_000_000_000),   // Extreme values: divide by 10^12
//        (1_000_000_000_000_001, 1_000_000_000), // Quadrillions: divide by 10^9
//        (1_000_000_000_001, 1_000),        // Trillions: divide by 1000
//        (1_000_000_001, 50),                // Billions: divide by 50
//        (1_000_001, 5),                      // Millions: divide by 5
//        (100_001, 2),                        // Hundred thousands: divide by 2
//    ]
//    
//    static let intReductionStrategy: [(threshold: UInt64, factor: UInt64)] = [
//        (UInt64(Int64.max) / 2, 1_000_000_000_000), // Extreme values: divide by 10^12
//        (1_000_000_000_000_001, 1_000_000_000),     // Quadrillions: divide by 10^9
//        (1_000_000_000_001, 1_000),             // Trillions: divide by 1000
//        (1_000_000_001, 50),                     // Billions: divide by 50
//        (1_000_001, 5),                           // Millions: divide by 5
//        (100_001, 2),                             // Hundred thousands: divide by 2
//    ]
//    
//    func next(for value: Double) -> Double? {
//        guard value.isFinite else {
//            return nil
//        }
//        let strategicDivisor = Self.doubleReductionStrategy.first(where: { value > $0.threshold })?.factor ?? 2
//        let next: Double = switch direction {
//        case .towardsLowerBound where value < 0:
//            value * strategicDivisor
//        case .towardsLowerBound where value == 0:
//            -1
//        case .towardsLowerBound where value > 0:
//            value / strategicDivisor
//        case .towardsHigherBound where value < 0:
//            value / strategicDivisor
//        case .towardsHigherBound where value == 0:
//            1
//        case .towardsHigherBound where value > 0:
//            value * strategicDivisor
//        default:
//            fatalError("Reducer error")
//        }
//        return next == value ? nil : next
//    }
//    
//    // MARK: - LazyChoiceSequenceReducerStrategy
//    
//    func next(for collection: [ChoiceTree].SubSequence) -> [[ChoiceTree].SubSequence] {
//        guard collection.count > 1 else {
//            return []
//        }
//        let count = collection.count
//        let halved = count / 2
//        var subsequences = [[ChoiceTree].SubSequence]()
//        subsequences.append(collection.prefix(halved))
//        subsequences.append(collection.suffix(count - halved))
//        return subsequences
//    }
//}
