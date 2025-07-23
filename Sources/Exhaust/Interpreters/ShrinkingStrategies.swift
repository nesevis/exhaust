//
//  ShrinkingStrategies.swift
//  Exhaust
//
//  Created by Chris Kolbu on 22/7/2025.
//

enum ShrinkingStrategy: CaseIterable, Hashable, Equatable {
    /// Magic custom values representing common error sources
    case fundamentals
    /// max, inf, nan, ulp, shearing off the prefix and suffix, ascii/unicode boundaries and special characters
    case boundaries
    /// floor/ceil for doubles, etc
    case patterns
    /// halve and halve again
    case binary
    /// round to powers of two
    case decimal
    /// Exhaustive search around narrow range
    case saturation // divide by 5
    case ultraSaturation
    
    /// Handy in-order sets
    static let unsignedIntegers: [Self] = [.fundamentals, .boundaries, .binary]
    static let signedIntegers: [Self] = unsignedIntegers
    static let floatingPoints: [Self] = unsignedIntegers
    static let characters: [Self] = unsignedIntegers
    static let sequences: [Self] = [.fundamentals, .binary, .boundaries]
}

struct ShrinkingStrategies: OptionSet, Equatable {
    var rawValue: UInt64
    
    static let unsignedIntegers: Self = [.fundamentals, .boundary, .binary]
    static let signedIntegers: Self = unsignedIntegers.union([])
    static let floatingPoints: Self = signedIntegers.union([])
    static let sequences: Self = unsignedIntegers.union([])
    
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
