//
//  ChoiceMetadata.swift
//  Exhaust
//
//  Created by Chris Kolbu on 21/7/2025.
//

public struct ChoiceMetadata: Hashable, Equatable, Sendable {
    private static let noStrategies = [any TemporaryDualPurposeStrategy]()
    // `Character` has discontiguous ranges, and `RangeSet` isn't available until the very newest releases
    let validRanges: [ClosedRange<UInt64>]
    let strategies: [any TemporaryDualPurposeStrategy]
    
    init(validRanges: [ClosedRange<UInt64>], strategies: [any TemporaryDualPurposeStrategy]) {
        self.validRanges = validRanges
        self.strategies = strategies
    }
    
    init(validRanges: [ClosedRange<UInt64>]) {
        self.validRanges = validRanges
        self.strategies = Self.noStrategies
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(validRanges)
    }
    
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hashValue == rhs.hashValue
    }
}
