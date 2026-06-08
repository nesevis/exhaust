//
//  ChooseBitsBitPattern.swift
//  Exhaust
//

/// Recovers the `UInt64` bit pattern from a `chooseBits` continuation's input.
///
/// Generation passes the drawn bits as a boxed `UInt64`, so the concrete cast is the hot path; the existential branch covers reflection, which feeds a typed `BitPatternConvertible` value. Centralizing this keeps every `chooseBits` continuation off the slow `as? any BitPatternConvertible` cast.
@inline(__always)
package func chooseBitsBitPattern(_ result: Any) throws -> UInt64 {
    if let bits = result as? UInt64 {
        return bits
    }
    if let convertible = result as? any BitPatternConvertible { return convertible.bitPattern64
    }
    throw GeneratorError.typeMismatch(
        expected: "UInt64 or any BitPatternConvertible",
        actual: String(describing: type(of: result))
    )
}
