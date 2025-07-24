//
//  ChoiceMetadata.swift
//  Exhaust
//
//  Created by Chris Kolbu on 21/7/2025.
//

struct ChoiceMetadata: Hashable, Equatable, Sendable {
    // `Character` has discontiguous ranges, and `RangeSet` isn't available until the very newest releases
    let validRanges: [ClosedRange<UInt64>]
    let strategies: [any TemporaryDualPurposeStrategy]
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(validRanges)
    }
    
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hashValue == rhs.hashValue
    }
}
