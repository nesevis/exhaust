////
////  BoundaryReducerStrategy.swift
////  Exhaust
////
////  Created by Chris Kolbu on 24/7/2025.
////
//
//struct BoundaryReducerStrategy: LazyChoiceValueReducerStrategy, LazyChoiceSequenceReducerStrategy {
//    let direction: ShrinkingDirection
//    
//    private static let uintValues: [UInt64] = [.min, .max]
//    func next(for value: UInt64) -> UInt64? {
//        guard Self.uintValues.contains(value) else {
//            return Self.uintValues[0]
//        }
//        if let index = Self.uintValues.firstIndex(of: value), index < Self.uintValues.endIndex - 1 {
//            return Self.uintValues[index + 1]
//        }
//        return nil
//    }
//    
//    private static let intValues: [Int64] = [.min, .max]
//    func next(for value: Int64) -> Int64? {
//        guard Self.intValues.contains(value) else {
//            return Self.intValues[0]
//        }
//        if let index = Self.intValues.firstIndex(of: value), index < Self.intValues.endIndex - 1 {
//            return Self.intValues[index + 1]
//        }
//        return nil
//    }
//    
//    private static let doubleValues = [
//        Double.greatestFiniteMagnitude / 100000000,
//        Double.greatestFiniteMagnitude / 10000000,
//        Double.greatestFiniteMagnitude / 1000000,
//        Double.greatestFiniteMagnitude / 100000,
//        Double.greatestFiniteMagnitude / 10000,
//        Double.greatestFiniteMagnitude / 1000,
//        Double.greatestFiniteMagnitude / 100,
//        Double.greatestFiniteMagnitude,
//        -Double.greatestFiniteMagnitude,
//        -Double.greatestFiniteMagnitude / 100,
//        -Double.greatestFiniteMagnitude / 1000,
//        -Double.greatestFiniteMagnitude / 10000,
//        -Double.greatestFiniteMagnitude / 100000,
//        -Double.greatestFiniteMagnitude / 1000000,
//        -Double.greatestFiniteMagnitude / 10000000,
//        -Double.greatestFiniteMagnitude / 100000000,
//    ]
//    func next(for value: Double) -> Double? {
//        guard Self.doubleValues.contains(value) else {
//            return Self.doubleValues[0]
//        }
//        if let index = Self.doubleValues.firstIndex(of: value), index < Self.doubleValues.endIndex - 1 {
//            return Self.doubleValues[index + 1]
//        }
//        return nil
//    }
//    
//    func next(for value: Character) -> Character? {
//        // TOOD: Edge cases and control characters?
//        nil
//    }
//    
//    // MARK: - ChoiceSequenceReducerStrategy
//    
//    func next(for collection: [ChoiceTree].SubSequence) -> [[ChoiceTree].SubSequence] {
//        [
//            collection.dropFirst().dropLast(),
//            collection.dropLast(),
//            collection.dropFirst()
//        ]
//    }
//}
