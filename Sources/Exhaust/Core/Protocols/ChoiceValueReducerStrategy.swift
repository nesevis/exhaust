//
//  ChoiceValueReducerStrategy.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/7/2025.
//

typealias TemporaryDualPurposeStrategy = LazyChoiceValueReducerStrategy & LazyChoiceSequenceReducerStrategy

protocol ChoiceValueReducerStrategy: Equatable, Hashable, Sendable {
    var direction: ShrinkingDirection { get }
    func values(for value: UInt64, in range: ClosedRange<UInt64>) -> [UInt64]
    func values(for value: Int64, in range: ClosedRange<Int64>) -> [Int64]
    func values(for value: Double, in range: ClosedRange<Double>) -> [Double]
    func values(for value: Character, in ranges: [ClosedRange<Character>]) -> [Character]
}

extension ChoiceValueReducerStrategy {
    /// The characer reduction path is usually defined in terms of that of the unsigned integer
    func values(for value: Character, in ranges: [ClosedRange<Character>]) -> [Character] {
        guard let range = ranges.first(where: { $0.contains(value) }) else {
            return []
        }
        let uintRange = range.lowerBound.bitPattern64...range.upperBound.bitPattern64
        let uints = self.values(for: value.bitPattern64, in: uintRange)
        return uints.map(Character.init(bitPattern64:))
    }
}

protocol ChoiceSequenceReducerStrategy: Equatable, Hashable, Sendable {
    var direction: ShrinkingDirection { get }
    func values(for collection: some Collection, in lengthRange: ClosedRange<Int>) -> [any Collection]
}

// MARK: - Lazy

// A version of the protocol that works with lazy iterators

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

