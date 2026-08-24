//
//  LengthConversion.swift
//  Exhaust
//

import ExhaustCore

/// Converts the public API's `Int`-typed lengths, counts, and scalings to the `UInt64` forms the core generators consume, validating non-negativity at the boundary.
enum LengthConversion {
    /// Converts a non-negative `Int` length range to the `UInt64` range the core generators consume.
    static func uint64Range(_ length: ClosedRange<Int>) -> ClosedRange<UInt64> {
        precondition(length.lowerBound >= 0, "Length must be non-negative")
        return UInt64(length.lowerBound) ... UInt64(length.upperBound)
    }

    /// Converts an `Int`-typed length scaling to the `UInt64` scaling the core generators consume.
    static func uint64Scaling(_ scaling: SizeScaling<Int>) -> SizeScaling<UInt64> {
        switch scaling {
            case .constant:
                return .constant
            case .linear:
                return .linear
            case let .linearFrom(origin):
                precondition(origin >= 0, "Origin must be non-negative")
                return .linearFrom(origin: UInt64(origin))
            case .exponential:
                return .exponential
            case let .exponentialFrom(origin):
                precondition(origin >= 0, "Origin must be non-negative")
                return .exponentialFrom(origin: UInt64(origin))
        }
    }
}
