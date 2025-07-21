//
//  Shrinkable.swift
//  Exhaust
//
//  Created by Chris Kolbu on 20/7/2025.
//

// Not used anywhere - ignore

extension UInt64: Shrinkable {
    var shrinkingStrategies: ShrinkingStrategies {
        [.binary, .decimal, .deletion, .minimal]
    }
}


protocol Shrinkable: Comparable, Hashable, Equatable {
    var shrinkingStrategies: ShrinkingStrategies { get }
}

struct ShrinkingStrategies: OptionSet, Equatable {
    var rawValue: UInt64
    
    static let unsignedIntegers: Self = [.binary, .minimal]
    static let signedIntegers: Self = unsignedIntegers.union([.signed])
    static let floatingPoints: Self = signedIntegers.union([.decimal])
    static let sequences: Self = unsignedIntegers.union([.deletion])
    
    // Booleans
    static let signed = Self(rawValue: 1 << 1)
    static let orderMatters = Self(rawValue: 1 << 2)
    
    // Strategies
    static let binary = Self(rawValue: 1 << 3) // divide by two
    static let decimal = Self(rawValue: 1 << 4) // round to powers of two
    static let minimal = Self(rawValue: 1 << 5) // try 0, 1, -1 first)
    
    // Sequence-specific
    static let deletion = Self(rawValue: 1 << 6) // can be removed?
    
    // Can shrink to zero
    // Is signed
    // binary (divide by two)
    // decimal (round to powers of two)
    // minimal (try 0, 1, -1 first)
    // deletion (can be removed) is optional!
    // orderMatters (sequences)
    //
}
