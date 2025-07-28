//
//  ChoiceValueReducerStrategy.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/7/2025.
//

typealias TemporaryDualPurposeStrategy = LazyChoiceValueReducerStrategy & LazyChoiceSequenceReducerStrategy

protocol LazyChoiceValueReducerStrategy: Equatable, Hashable, Sendable {
    var direction: ShrinkingDirection { get }
    func next(for value: UInt64) -> UInt64?
    func next(for value: Int64) -> Int64?
    func next(for value: Double) -> Double?
    func next(for value: Character) -> Character?
}

extension LazyChoiceValueReducerStrategy {
    /// The characer reduction path is usually defined in terms of that of the unsigned integer
    func next(for value: Character) -> Character? {
        self.next(for: value.bitPattern64)
            .map { Character(bitPattern64: $0) }
    }
}

protocol LazyChoiceSequenceReducerStrategy: Equatable, Hashable, Sendable {
    var direction: ShrinkingDirection { get }
    func next(for collection: [ChoiceTree].SubSequence) -> [[ChoiceTree].SubSequence]
}

