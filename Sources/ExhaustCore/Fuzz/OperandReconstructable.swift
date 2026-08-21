// Reconstructs a value from a trace-cmp operand word, in the type's natural encoding.

import Foundation

/// Rebuilds a value of the conforming type from a comparison operand word harvested by trace-cmp.
///
/// The word carries the type's **natural** machine encoding — the representation the system under test actually compared: two's-complement for a signed integer, IEEE 754 for a floating-point value, little-endian UTF-8 for a string. This is deliberately not ``BitPatternConvertible``, which is Exhaust's internal order-preserving choice-space encoding (sign-bit XOR, Hedgehog transform); feeding a natural word through that would misinterpret it. The value produced here is a natural value; ``Interpreters/reflect(_:with:where:)`` is what converts it into choice space, applying the generator's own leaf encoding on the way.
///
/// Reconstruction is partial by nature. A fixed-width scalar always decodes (its bytes are its representation); a `String` decodes only when the bytes are valid, non-control UTF-8, so the flag word of a small-string comparison or an unrelated integer operand is rejected. Whatever survives is offered to reflection, whose domain check rejects values outside the generator's declared range — so this type never has to know the range, only the encoding.
///
/// - Note: The trace-cmp hooks widen a `cmp1`/`cmp2`/`cmp4` operand into the 64-bit word and drop the real width. A narrow, signed-negative operand therefore reconstructs into a 64-bit signed type as its zero-extended value: a `trace_cmp4` of `0xFFFFFFFF` becomes `Int(4294967295)`, not `Int(-1)`. The self-truncating narrow types (`Int32`, `Int16`, `Int8`) are unaffected, because they take only their own low bytes. Resolving the wide case needs the hooks to record the operand width, which they do not.
package protocol OperandReconstructable {
    /// Reconstructs a value from a harvested operand word, or nil when the word is not a natural value of this type.
    static func reconstruct(fromOperand word: UInt64) -> Self?
}

// MARK: - Derivation

/// Derives a natural-encoding reconstructor for a generator's output type from its ``OperandReconstructable`` conformance.
package enum OperandReconstruction {
    /// A reconstructor closure for `Output` when it conforms to ``OperandReconstructable``, or nil when it does not.
    ///
    /// Dispatches through a constrained generic rather than calling on the existential metatype directly, so the returned closure captures a concrete (Sendable) metatype instead of a `any OperandReconstructable.Type`.
    package static func reconstructor<Output>(for _: Output.Type) -> (@Sendable (UInt64) -> Output?)? {
        guard let conforming = Output.self as? any OperandReconstructable.Type else {
            return nil
        }
        return makeReconstructor(conforming, as: Output.self)
    }

    private static func makeReconstructor<Conforming: OperandReconstructable, Output>(
        _: Conforming.Type,
        as _: Output.Type
    ) -> (@Sendable (UInt64) -> Output?) {
        { word in Conforming.reconstruct(fromOperand: word) as? Output }
    }

    /// A reconstructor for a runtime output type when it conforms to ``OperandReconstructable``, or nil when it does not.
    ///
    /// The typed ``reconstructor(for:)`` needs the type statically. Reflecting one field of a composite recovers the field's type at runtime from the parent value, so this variant keys on a runtime metatype and erases the result to `Any?`.
    package static func erasedReconstructor(for type: Any.Type) -> (@Sendable (UInt64) -> Any?)? {
        guard let conforming = type as? any OperandReconstructable.Type else {
            return nil
        }
        return makeErasedReconstructor(conforming)
    }

    private static func makeErasedReconstructor<Conforming: OperandReconstructable>(
        _: Conforming.Type
    ) -> (@Sendable (UInt64) -> Any?) {
        { word in Conforming.reconstruct(fromOperand: word) }
    }
}

// MARK: - Integer Conformances

//
// The operand word is the value's two's-complement representation, so a signed type reinterprets it through the standard-library `init(bitPattern:)` (or `init(truncatingIfNeeded:)` for narrower types), never through Exhaust's order-preserving `bitPattern64`.

extension Int: OperandReconstructable {
    package static func reconstruct(fromOperand word: UInt64) -> Int? {
        Int(bitPattern: UInt(truncatingIfNeeded: word))
    }
}

extension Int64: OperandReconstructable {
    package static func reconstruct(fromOperand word: UInt64) -> Int64? {
        Int64(bitPattern: word)
    }
}

extension Int32: OperandReconstructable {
    package static func reconstruct(fromOperand word: UInt64) -> Int32? {
        Int32(bitPattern: UInt32(truncatingIfNeeded: word))
    }
}

extension Int16: OperandReconstructable {
    package static func reconstruct(fromOperand word: UInt64) -> Int16? {
        Int16(bitPattern: UInt16(truncatingIfNeeded: word))
    }
}

extension Int8: OperandReconstructable {
    package static func reconstruct(fromOperand word: UInt64) -> Int8? {
        Int8(bitPattern: UInt8(truncatingIfNeeded: word))
    }
}

extension UInt: OperandReconstructable {
    package static func reconstruct(fromOperand word: UInt64) -> UInt? {
        UInt(truncatingIfNeeded: word)
    }
}

extension UInt64: OperandReconstructable {
    package static func reconstruct(fromOperand word: UInt64) -> UInt64? {
        word
    }
}

extension UInt32: OperandReconstructable {
    package static func reconstruct(fromOperand word: UInt64) -> UInt32? {
        UInt32(truncatingIfNeeded: word)
    }
}

extension UInt16: OperandReconstructable {
    package static func reconstruct(fromOperand word: UInt64) -> UInt16? {
        UInt16(truncatingIfNeeded: word)
    }
}

extension UInt8: OperandReconstructable {
    package static func reconstruct(fromOperand word: UInt64) -> UInt8? {
        UInt8(truncatingIfNeeded: word)
    }
}

// MARK: - Floating-Point Conformances

//
// The word is the value's IEEE 754 bit pattern.

extension Double: OperandReconstructable {
    package static func reconstruct(fromOperand word: UInt64) -> Double? {
        Double(bitPattern: word)
    }
}

extension Float: OperandReconstructable {
    package static func reconstruct(fromOperand word: UInt64) -> Float? {
        Float(bitPattern: UInt32(truncatingIfNeeded: word))
    }
}

// MARK: - String Conformance

//
// A small-string equality compares two 64-bit words; the first holds up to eight UTF-8 content bytes. Reconstruction takes the operand's bytes, drops trailing padding, and accepts them only as valid, non-control UTF-8 — which rejects the small-string flag word (its low bytes are zero) and unrelated integer operands, while accepting a genuine short string.

extension String: OperandReconstructable {
    package static func reconstruct(fromOperand word: UInt64) -> String? {
        var content = withUnsafeBytes(of: word.littleEndian) { Array($0) }
        while content.last == 0 {
            content.removeLast()
        }
        guard content.isEmpty == false, content.allSatisfy({ $0 >= 0x20 }) else {
            return nil
        }
        return String(bytes: content, encoding: .utf8)
    }
}
