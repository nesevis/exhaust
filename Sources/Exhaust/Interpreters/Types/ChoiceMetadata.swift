//
//  ChoiceMetadata.swift
//  Exhaust
//
//  Created by Chris Kolbu on 21/7/2025.
//

public struct ChoiceMetadata: Hashable, Equatable, Sendable {
    /// `Character` has discontiguous ranges, and `RangeSet` isn't available until the very newest releases
    public let validRanges: [ClosedRange<UInt64>]

    public func hash(into hasher: inout Hasher) {
        hasher.combine(validRanges)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hashValue == rhs.hashValue
    }
}
