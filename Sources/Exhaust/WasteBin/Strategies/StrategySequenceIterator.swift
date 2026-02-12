////
////  StrategySequenceIterator.swift
////  Exhaust
////
////  Created by Chris Kolbu on 28/7/2025.
////
//
//final class StrategySequenceIterator: IteratorProtocol, AnyStrategyIterator {
//    typealias Convertible = [ChoiceTree]
//    let nextValues: (Convertible.SubSequence) -> [Convertible.SubSequence]?
//    let output: (Convertible.SubSequence) -> ChoiceTree?
//    private var initial: Convertible.SubSequence
//    private var currentBatch: [Convertible.SubSequence].SubSequence?
//    let strategy: any TemporaryDualPurposeStrategy
//    let range: ClosedRange<Int>
//    var outOfRangeHits = 0
//
//    init(initial: Convertible, strategy: any TemporaryDualPurposeStrategy, inRange: ClosedRange<Int>, _ transform: @escaping (Convertible.SubSequence) -> [Convertible.SubSequence]?, output: @escaping (Convertible.SubSequence) -> ChoiceTree?) {
//        // The sequence to use as a basis
//        self.initial = initial[...]
//        self.strategy = strategy
//        self.range = inRange
//        // The transform that returns a sequence of sequences as alternatives
//        self.nextValues = transform
//        // The transform for each of these sequences into a new sequence for the shrinker
//        self.output = output
//    }
//    
//    func next() -> ChoiceTree? {
//        if currentBatch?.first == nil, let next = nextValues(initial) {
//            guard next.isEmpty == false else {
//                print("❌\(Self.self)/\(type(of: strategy)).\(strategy.direction) [Exhausted]")
//                return nil
//            }
//            currentBatch = next[...]
//            initial = currentBatch?.first ?? initial
//        }
//        guard let next = currentBatch?.first else {
//            print("❌\(Self.self)/\(type(of: strategy)).\(strategy.direction) [Exhausted]")
//            return nil
//        }
//        currentBatch = currentBatch?.dropFirst()
//
//        guard range.contains(next.count) else {
//            outOfRangeHits += 1
//            print("❌\(Self.self)/\(type(of: strategy)).\(strategy.direction) [OOR:\(outOfRangeHits)] \(next.count)")
//            if outOfRangeHits >= 5 {
//                outOfRangeHits = 0
//                return nil
//            }
//            return self.next()
//        }
//        print("✅\(Self.self)/\(type(of: strategy)).\(strategy.direction) \(next.count)")
//        return output(next)
//    }
//}
