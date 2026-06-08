//
//  ReflectiveGenerator+UUID.swift
//  Exhaust
//

import ExhaustCore
import Foundation

public extension ReflectiveGenerator {
    /// Generates valid UUID v4 values.
    ///
    /// UUID v4 has 122 random bits with a fixed version nibble (`4`) and variant bits (`10`). Two `UInt64` generators produce exactly 122 random bits (60 + 62) — the mapping is bijective.
    ///
    /// ```swift
    /// let gen = #gen(.uuid())
    /// ```
    static func uuid() -> ReflectiveGenerator<UUID> {
        Gen.uuid()
    }
}
