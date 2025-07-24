//
//  ChoiceValueReducerStrategy.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/7/2025.
//

typealias TemporaryDualPurposeStrategy = ChoiceValueReducerStrategy & ChoiceSequenceReducerStrategy

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


