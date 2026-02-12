////
////  StrategyIterator.swift
////  Exhaust
////
////  Created by Chris Kolbu on 28/7/2025.
////
//
//protocol AnyStrategyIterator {
//    associatedtype Convertible
//    
//    func next() -> ChoiceTree?
//}
//
//final class StrategyIterator<T: BitPatternConvertible & Comparable>: IteratorProtocol, AnyStrategyIterator {
//    typealias Convertible = T
//
//    private var current: T
//    let strategy: any TemporaryDualPurposeStrategy
//    let nextValue: (T) -> T?
//    let output: (T) -> ChoiceTree?
//    let ranges: [ClosedRange<T>]
//    var outOfRangeHits = 0
//    
//    init(initial: T, strategy: any TemporaryDualPurposeStrategy, inRange: [ClosedRange<T>], _ transform: @escaping (T) -> T?, output: @escaping (T) -> ChoiceTree?) {
//        self.current = initial
//        self.strategy = strategy
//        self.ranges = inRange
//        self.nextValue = transform
//        self.output = output
//    }
//    
//    func next() -> ChoiceTree? {
//        guard let this = nextValue(current) else {
//            print("❌\(Self.self)/\(type(of: strategy)).\(strategy.direction) [Exhausted] \(current)")
//            return nil
//        }
//        current = this
//        guard ranges.contains(where: { $0.contains(this) }) else {
//            outOfRangeHits += 1
//            print("❌\(Self.self)/\(type(of: strategy)).\(strategy.direction) [OOR:\(outOfRangeHits)] \(current) -> \(this)")
//            if outOfRangeHits >= 5 {
//                outOfRangeHits = 0
//                return nil
//            }
//            return next()
//        }
//        print("✅\(Self.self)/\(type(of: strategy)).\(strategy.direction) \(current) -> \(this)")
//        // Now compare the range or call `next` recursively?
//        return output(this)
//    }
//}
