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
        Gen.zip(
            Gen.chooseBits(in: 0 ... 0x0FFF_FFFF_FFFF_FFFF),  // 60 bits → bytes 0–7
            Gen.chooseBits(in: 0 ... 0x3FFF_FFFF_FFFF_FFFF)   // 62 bits → bytes 8–15
        ).mapped(
            forward: { uuidFromHalves($0, $1) },
            backward: { uuidToHalves($0) }
        )
    }
}

// MARK: - UUID v4 Bit Layout
//
// Bytes 0–7 (high UInt64, big-endian):
//   bits 63–16: 48 random bits (bytes 0–5)
//   bits 15–12: version nibble = 0x4
//   bits 11–0:  12 random bits (byte 6 low nibble + byte 7)
//   Total: 60 random bits
//
// Bytes 8–15 (low UInt64, big-endian):
//   bits 63–62: variant = 0b10
//   bits 61–0:  62 random bits
//   Total: 62 random bits
//
// Generators produce only the random bits; fixed bits are inserted/stripped
// in the forward/backward functions below.

private extension ReflectiveGenerator {
    static func uuidFromHalves(_ high60: UInt64, _ low62: UInt64) -> UUID {
        let highU64 = ((high60 >> 12) << 16) | (0x4 << 12) | (high60 & 0xFFF)
        let lowU64 = 0x8000_0000_0000_0000 | low62

        var bytes: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &bytes) { buf in
            buf.storeBytes(of: highU64.bigEndian, as: UInt64.self)
            buf.storeBytes(of: lowU64.bigEndian, toByteOffset: 8, as: UInt64.self)
        }
        return UUID(uuid: bytes)
    }

    static func uuidToHalves(_ uuid: UUID) -> (UInt64, UInt64) {
        withUnsafeBytes(of: uuid.uuid) { buf in
            let rawHigh = UInt64(bigEndian: buf.loadUnaligned(as: UInt64.self))
            let rawLow = UInt64(bigEndian: buf.loadUnaligned(fromByteOffset: 8, as: UInt64.self))

            let high60 = ((rawHigh >> 16) << 12) | (rawHigh & 0xFFF)
            let low62 = rawLow & 0x3FFF_FFFF_FFFF_FFFF

            return (high60, low62)
        }
    }
}
