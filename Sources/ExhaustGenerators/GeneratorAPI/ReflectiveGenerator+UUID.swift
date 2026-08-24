//
//  ReflectiveGenerator+UUID.swift
//  Exhaust
//

import ExhaustCore
import Foundation

public extension ReflectiveGenerator {
    /// Generates valid UUID v4 values.
    ///
    /// UUID v4 has 122 random bits with a fixed version nibble (`4`) and variant bits (`10`), matching Foundation's `UUID()` initializer. Reflection accepts every value representable by `Foundation.UUID`; replay preserves its 122 payload bits while normalizing the version and variant bits to v4.
    ///
    /// ```swift
    /// let gen = #gen(.uuid())
    /// ```
    static func uuid() -> ReflectiveGenerator<UUID> {
        Gen.uuid()
    }
}
