//
//  ChoiceMetadata.swift
//  Exhaust
//
//  Created by Chris Kolbu on 21/7/2025.
//

struct ChoiceMetadata: Hashable, Equatable {
    // `Character` has discontiguous ranges, and `RangeSet` isn't available until the very newest releases
    let validRanges: [ClosedRange<UInt64>]
    let strategies: [ShrinkingStrategy]
    
    func isValidForRange(_ value: UInt64) -> Bool {
        // FIXME: This does not return correct results for doubles; it returns no negative values
        // Check signed ints
        validRanges.contains(where: { $0.contains(value) })
    }
}
