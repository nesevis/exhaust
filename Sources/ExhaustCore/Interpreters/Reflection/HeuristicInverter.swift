//
//  HeuristicInverter.swift
//  Exhaust
//
//  Attempts to invert forward-only map transforms for trivially invertible
//  type conversions (e.g. Int → Double). Guarded by round-trip validation
//  so lossy conversions are rejected.

/// Provides heuristic inversion for forward-only `.map()` transforms between known Swift numeric types.
///
/// When reflection encounters a forward-only map, `HeuristicInverter` checks whether the input and output types
/// are both known numeric types. If so, it returns a closure that converts the output value back to the input type.
/// A round-trip check (`forward(invert(output)) == output`) ensures correctness before the inverted value is used.
enum HeuristicInverter {
    /// Returns an inverter closure if the input→output type pair is a known numeric conversion, or `nil` otherwise.
    static func inverter(inputType: String, outputType: String) -> ((Any) throws -> Any)? {
        // Same type — identity
        if inputType == outputType {
            return { $0 }
        }

        // Both must be recognized numeric types
        guard let castToInput = numericCast[inputType],
              numericCast[outputType] != nil
        else {
            return nil
        }

        // The inverter casts the output (which is outputType) back to inputType
        return { outputValue in
            guard let converted = castToInput(outputValue) else {
                throw InversionError.castFailed(from: outputType, to: inputType)
            }
            return converted
        }
    }

    /// Checks whether two `Any` values are equivalent for round-trip validation.
    ///
    /// For numeric types, casts both to `Double` and compares. Falls back to `String(describing:)` equality.
    static func areEquivalent(_ a: Any, _ b: Any) -> Bool {
        // Try numeric comparison via Double
        if let da = toDouble(a), let db = toDouble(b) {
            return da == db
        }
        // Fallback: string representation
        return String(describing: a) == String(describing: b)
    }

    // MARK: - Private

    enum InversionError: Error {
        case castFailed(from: String, to: String)
    }

    /// Lookup table: type name → closure that casts `Any` to that type (returning nil on failure).
    private nonisolated(unsafe) static let numericCast: [String: (Any) -> Any?] = [
        // Signed integers
        "Int": { castToInt($0) },
        "Int8": { castToInt8($0) },
        "Int16": { castToInt16($0) },
        "Int32": { castToInt32($0) },
        "Int64": { castToInt64($0) },
        // Unsigned integers
        "UInt": { castToUInt($0) },
        "UInt8": { castToUInt8($0) },
        "UInt16": { castToUInt16($0) },
        "UInt32": { castToUInt32($0) },
        "UInt64": { castToUInt64($0) },
        // Floating point
        "Float": { castToFloat($0) },
        "Double": { castToDouble($0) },
    ]

    // MARK: - Cast helpers

    private static func castToInt(_ v: Any) -> Int? {
        switch v {
        case let x as Int: x
        case let x as Int8: Int(x)
        case let x as Int16: Int(x)
        case let x as Int32: Int(x)
        case let x as Int64: Int(exactly: x)
        case let x as UInt: Int(exactly: x)
        case let x as UInt8: Int(x)
        case let x as UInt16: Int(x)
        case let x as UInt32: Int(x)
        case let x as UInt64: Int(exactly: x)
        case let x as Float: Int(exactly: x)
        case let x as Double: Int(exactly: x)
        default: nil
        }
    }

    private static func castToInt8(_ v: Any) -> Int8? {
        switch v {
        case let x as Int: Int8(exactly: x)
        case let x as Int8: x
        case let x as Int16: Int8(exactly: x)
        case let x as Int32: Int8(exactly: x)
        case let x as Int64: Int8(exactly: x)
        case let x as UInt: Int8(exactly: x)
        case let x as UInt8: Int8(exactly: x)
        case let x as UInt16: Int8(exactly: x)
        case let x as UInt32: Int8(exactly: x)
        case let x as UInt64: Int8(exactly: x)
        case let x as Float: Int8(exactly: x)
        case let x as Double: Int8(exactly: x)
        default: nil
        }
    }

    private static func castToInt16(_ v: Any) -> Int16? {
        switch v {
        case let x as Int: Int16(exactly: x)
        case let x as Int8: Int16(x)
        case let x as Int16: x
        case let x as Int32: Int16(exactly: x)
        case let x as Int64: Int16(exactly: x)
        case let x as UInt: Int16(exactly: x)
        case let x as UInt8: Int16(x)
        case let x as UInt16: Int16(exactly: x)
        case let x as UInt32: Int16(exactly: x)
        case let x as UInt64: Int16(exactly: x)
        case let x as Float: Int16(exactly: x)
        case let x as Double: Int16(exactly: x)
        default: nil
        }
    }

    private static func castToInt32(_ v: Any) -> Int32? {
        switch v {
        case let x as Int: Int32(exactly: x)
        case let x as Int8: Int32(x)
        case let x as Int16: Int32(x)
        case let x as Int32: x
        case let x as Int64: Int32(exactly: x)
        case let x as UInt: Int32(exactly: x)
        case let x as UInt8: Int32(x)
        case let x as UInt16: Int32(x)
        case let x as UInt32: Int32(exactly: x)
        case let x as UInt64: Int32(exactly: x)
        case let x as Float: Int32(exactly: x)
        case let x as Double: Int32(exactly: x)
        default: nil
        }
    }

    private static func castToInt64(_ v: Any) -> Int64? {
        switch v {
        case let x as Int: Int64(x)
        case let x as Int8: Int64(x)
        case let x as Int16: Int64(x)
        case let x as Int32: Int64(x)
        case let x as Int64: x
        case let x as UInt: Int64(exactly: x)
        case let x as UInt8: Int64(x)
        case let x as UInt16: Int64(x)
        case let x as UInt32: Int64(x)
        case let x as UInt64: Int64(exactly: x)
        case let x as Float: Int64(exactly: x)
        case let x as Double: Int64(exactly: x)
        default: nil
        }
    }

    private static func castToUInt(_ v: Any) -> UInt? {
        switch v {
        case let x as Int: UInt(exactly: x)
        case let x as Int8: UInt(exactly: x)
        case let x as Int16: UInt(exactly: x)
        case let x as Int32: UInt(exactly: x)
        case let x as Int64: UInt(exactly: x)
        case let x as UInt: x
        case let x as UInt8: UInt(x)
        case let x as UInt16: UInt(x)
        case let x as UInt32: UInt(x)
        case let x as UInt64: UInt(exactly: x)
        case let x as Float: UInt(exactly: x)
        case let x as Double: UInt(exactly: x)
        default: nil
        }
    }

    private static func castToUInt8(_ v: Any) -> UInt8? {
        switch v {
        case let x as Int: UInt8(exactly: x)
        case let x as Int8: UInt8(exactly: x)
        case let x as Int16: UInt8(exactly: x)
        case let x as Int32: UInt8(exactly: x)
        case let x as Int64: UInt8(exactly: x)
        case let x as UInt: UInt8(exactly: x)
        case let x as UInt8: x
        case let x as UInt16: UInt8(exactly: x)
        case let x as UInt32: UInt8(exactly: x)
        case let x as UInt64: UInt8(exactly: x)
        case let x as Float: UInt8(exactly: x)
        case let x as Double: UInt8(exactly: x)
        default: nil
        }
    }

    private static func castToUInt16(_ v: Any) -> UInt16? {
        switch v {
        case let x as Int: UInt16(exactly: x)
        case let x as Int8: UInt16(exactly: x)
        case let x as Int16: UInt16(exactly: x)
        case let x as Int32: UInt16(exactly: x)
        case let x as Int64: UInt16(exactly: x)
        case let x as UInt: UInt16(exactly: x)
        case let x as UInt8: UInt16(x)
        case let x as UInt16: x
        case let x as UInt32: UInt16(exactly: x)
        case let x as UInt64: UInt16(exactly: x)
        case let x as Float: UInt16(exactly: x)
        case let x as Double: UInt16(exactly: x)
        default: nil
        }
    }

    private static func castToUInt32(_ v: Any) -> UInt32? {
        switch v {
        case let x as Int: UInt32(exactly: x)
        case let x as Int8: UInt32(exactly: x)
        case let x as Int16: UInt32(exactly: x)
        case let x as Int32: UInt32(exactly: x)
        case let x as Int64: UInt32(exactly: x)
        case let x as UInt: UInt32(exactly: x)
        case let x as UInt8: UInt32(x)
        case let x as UInt16: UInt32(x)
        case let x as UInt32: x
        case let x as UInt64: UInt32(exactly: x)
        case let x as Float: UInt32(exactly: x)
        case let x as Double: UInt32(exactly: x)
        default: nil
        }
    }

    private static func castToUInt64(_ v: Any) -> UInt64? {
        switch v {
        case let x as Int: UInt64(exactly: x)
        case let x as Int8: UInt64(exactly: x)
        case let x as Int16: UInt64(exactly: x)
        case let x as Int32: UInt64(exactly: x)
        case let x as Int64: UInt64(exactly: x)
        case let x as UInt: UInt64(x)
        case let x as UInt8: UInt64(x)
        case let x as UInt16: UInt64(x)
        case let x as UInt32: UInt64(x)
        case let x as UInt64: x
        case let x as Float: UInt64(exactly: x)
        case let x as Double: UInt64(exactly: x)
        default: nil
        }
    }

    private static func castToFloat(_ v: Any) -> Float? {
        switch v {
        case let x as Int: Float(x)
        case let x as Int8: Float(x)
        case let x as Int16: Float(x)
        case let x as Int32: Float(x)
        case let x as Int64: Float(x)
        case let x as UInt: Float(x)
        case let x as UInt8: Float(x)
        case let x as UInt16: Float(x)
        case let x as UInt32: Float(x)
        case let x as UInt64: Float(x)
        case let x as Float: x
        case let x as Double: Float(x)
        default: nil
        }
    }

    private static func castToDouble(_ v: Any) -> Double? {
        switch v {
        case let x as Int: Double(x)
        case let x as Int8: Double(x)
        case let x as Int16: Double(x)
        case let x as Int32: Double(x)
        case let x as Int64: Double(x)
        case let x as UInt: Double(x)
        case let x as UInt8: Double(x)
        case let x as UInt16: Double(x)
        case let x as UInt32: Double(x)
        case let x as UInt64: Double(x)
        case let x as Float: Double(x)
        case let x as Double: x
        default: nil
        }
    }

    /// Converts any recognized numeric value to Double for comparison.
    private static func toDouble(_ v: Any) -> Double? {
        switch v {
        case let x as Int: Double(x)
        case let x as Int8: Double(x)
        case let x as Int16: Double(x)
        case let x as Int32: Double(x)
        case let x as Int64: Double(x)
        case let x as UInt: Double(x)
        case let x as UInt8: Double(x)
        case let x as UInt16: Double(x)
        case let x as UInt32: Double(x)
        case let x as UInt64: Double(x)
        case let x as Float: Double(x)
        case let x as Double: x
        default: nil
        }
    }
}
