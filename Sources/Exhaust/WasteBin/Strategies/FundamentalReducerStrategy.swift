////
////  FundamentalReducerStrategy.swift
////  Exhaust
////
////  Created by Chris Kolbu on 24/7/2025.
////
//
//struct FundamentalReducerStrategy: LazyChoiceValueReducerStrategy, LazyChoiceSequenceReducerStrategy {
//    let direction: ShrinkingDirection
//    
//    static let uintValues: [UInt64] = [0, 1, 2]
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
//    static let intValues: [Int64] = [0, -1, 1, 2, -2]
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
//    static let doubleValues: [Double] = [0, -0.1, -0.01, -0.001, -Double.ulpOfOne, -0.0001, Double.ulpOfOne, 0.001, 0.01, 0.1]
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
//    static let charValues: [Character] = [" ", "a", "b", "c", "A", "B", "C", "0", "1", "2", "3", "\n", "\0"]
//    func next(for value: Character) -> Character? {
//        guard Self.charValues.contains(value) else {
//            return Self.charValues[0]
//        }
//        if let index = Self.charValues.firstIndex(of: value), index < Self.charValues.endIndex - 1 {
//            return Self.charValues[index + 1]
//        }
//        return nil
//    }
//    
//    // MARK: - LazyChoiceSequenceReducerStrategy
//    
//    func next(for collection: [ChoiceTree].SubSequence) -> [[ChoiceTree].SubSequence] {
//        [
//            [][...],
//            collection.prefix(1),
//            collection.suffix(1)
//        ]
//    }
//}
