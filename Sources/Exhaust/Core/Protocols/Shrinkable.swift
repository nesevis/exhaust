//
//  Shrinkable.swift
//  Exhaust
//
//  Created by Chris Kolbu on 20/7/2025.
//

extension UInt64: Shrinkable {
    var shrinkingStrategies: ShrinkingStrategies {
        [.binary, .decimal, .deletion, .minimal]
    }
}

struct ShrinkMetadata<T: Shrinkable> {
    let validRanges: Array<ClosedRange<T>>
}

protocol Shrinkable: Comparable, Hashable, Equatable {
    // `Character` has discontiguous ranges, and `RangeSet` isn't available for most users
    var shrinkingStrategies: ShrinkingStrategies { get }
}

struct ShrinkingStrategies: OptionSet, Equatable {
    var rawValue: UInt64
    
    // Booleans
    static let signed = Self(rawValue: 1 << 1)
    static let orderMatters = Self(rawValue: 1 << 2)
    
    // Strategies
    static let binary = Self(rawValue: 1 << 3) // divide by two
    static let decimal = Self(rawValue: 1 << 3) // round to powers of two
    static let minimal = Self(rawValue: 1 << 3) // try 0, 1, -1 first)
    static let deletion = Self(rawValue: 1 << 3) // can be removed?
    
    // Can shrink to zero
    // Is signed
    // binary (divide by two)
    // decimal (round to powers of two)
    // minimal (try 0, 1, -1 first)
    // deletion (can be removed) is optional!
    // orderMatters (sequences)
    //
}
