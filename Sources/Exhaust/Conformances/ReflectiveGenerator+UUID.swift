//
//  ReflectiveGenerator+UUID.swift
//  Exhaust
//

import ExhaustCore
import Foundation

public extension ReflectiveGenerator {
    /// Generates valid UUID v4 values.
    ///
    /// UUID v4 has 122 random bits with a fixed version nibble (`4`) and
    /// variant bits (`10`). Four `UInt32` generators produce exactly 122
    /// random bits (32 + 28 + 30 + 32) — the mapping is bijective.
    ///
    /// ```swift
    /// let gen = #gen(.uuid())
    /// ```
    static func uuid() -> ReflectiveGenerator<UUID> {
        Gen.zip(
            Gen.choose(in: UInt32(0) ... .max),          // 32 bits → bytes 0–3
            Gen.choose(in: UInt32(0) ... 0x0FFF_FFFF),   // 28 bits → bytes 4–7
            Gen.choose(in: UInt32(0) ... 0x3FFF_FFFF),   // 30 bits → bytes 8–11
            Gen.choose(in: UInt32(0) ... .max)           // 32 bits → bytes 12–15
        ).mapped(
            forward: { uuidFromParts($0, $1, $2, $3) },
            backward: { uuidToParts($0) }
        )
    }
}

// MARK: - UUID v4 Bit Layout
//
// Byte 6 high nibble = version (0x4), byte 8 top 2 bits = variant (0b10).
// Generators produce only the random bits; fixed bits are inserted/stripped
// in the forward/backward functions below.

private extension ReflectiveGenerator {
    static func uuidFromParts(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UUID {
        var bytes: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &bytes) { buf in
            buf.storeBytes(of: a.bigEndian, as: UInt32.self)
            buf.storeBytes(of: ((b & 0x0FFF_F000) << 4 | 0x0000_4000 | (b & 0x0000_0FFF)).bigEndian,
                           toByteOffset: 4, as: UInt32.self)
            buf.storeBytes(of: (0x8000_0000 as UInt32 | c).bigEndian,
                           toByteOffset: 8, as: UInt32.self)
            buf.storeBytes(of: d.bigEndian, toByteOffset: 12, as: UInt32.self)
        }
        return UUID(uuid: bytes)
    }

    static func uuidToParts(_ uuid: UUID) -> (UInt32, UInt32, UInt32, UInt32) {
        withUnsafeBytes(of: uuid.uuid) { buf in
            let a = UInt32(bigEndian: buf.loadUnaligned(as: UInt32.self))
            let raw4 = UInt32(bigEndian: buf.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            let b = ((raw4 >> 4) & 0x0FFF_F000) | (raw4 & 0x0000_0FFF)
            let c = UInt32(bigEndian: buf.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) & 0x3FFF_FFFF
            let d = UInt32(bigEndian: buf.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
            return (a, b, c, d)
        }
    }
}
