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
        validRanges.contains(where: { $0.contains(value) })
    }
}
