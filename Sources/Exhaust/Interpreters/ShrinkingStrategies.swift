//
//  ShrinkingStrategies.swift
//  Exhaust
//
//  Created by Chris Kolbu on 22/7/2025.
//

struct ShrinkingStrategies: OptionSet, Equatable {
    var rawValue: UInt64
    
    static let unsignedIntegers: Self = [.fundamentals, .boundary, .binary, .saturation]
    static let signedIntegers: Self = unsignedIntegers.union([.boundary, .patterns])
    static let floatingPoints: Self = signedIntegers.union([.decimal])
    static let sequences: Self = unsignedIntegers.union([.deletion])
    
    // Strategies — Value indicates order of preference
    static let fundamentals = Self(rawValue: 1 << 1) // Magic values for its type
    static let boundary = Self(rawValue: 1 << 2) // max, min, inf, nan, ulp, lopping off the prefix and suffix, ascii/unicode boundaries
    static let patterns = Self(rawValue: 1 << 3) // floor, ceil
    static let binary = Self(rawValue: 1 << 4) // divide by two
    static let decimal = Self(rawValue: 1 << 5) // round to powers of two
    static let saturation = Self(rawValue: 1 << 6) // exhaustive search around narrow range
    
    // Sequence-specific
    static let deletion = Self(rawValue: 1 << 7) // can be removed?
    static let orderMatters = Self(rawValue: 1 << 8) // Sets
}
