//
//  ZobristHash.swift
//  Exhaust
//
//  Created by Chris Kolbu on 15/3/2026.
//

/// Zobrist hashing utilities for ``ChoiceSequence`` duplicate detection during reduction.
///
/// Computes position-dependent XOR hashes that support O(1) incremental updates when single elements change. Used by reducer code for PRNG seeding and ``ReducerCache`` lookups.
package enum ZobristHash {
    /// Computes a Zobrist hash: XOR of position-dependent contributions for each element.
    /// Enables O(1) incremental updates when single elements change.
    static func hash(of sequence: ChoiceSequence) -> UInt64 {
        sequence.withUnsafeBufferPointer { buffer in
            var hash: UInt64 = 0
            var i = 0
            while i < buffer.count {
                hash ^= contribution(at: i, buffer[i])
                i += 1
            }
            return hash
        }
    }

    /// Computes the hash of `probe` incrementally from a cached `baseHash` and `baseSequence`.
    ///
    /// Scans for differing positions between `baseSequence` and `probe`, then XOR-updates the base hash with removed and added contributions. Avoids splitmix64 mixing for unchanged elements. For k changed positions out of n total, cost is O(n) comparison + O(k) mixing instead of O(n) mixing.
    static func incrementalHash(
        baseHash: UInt64,
        baseSequence: ChoiceSequence,
        probe: ChoiceSequence
    ) -> UInt64 {
        baseSequence.withUnsafeBufferPointer { baseBuffer in
            probe.withUnsafeBufferPointer { probeBuffer in
                var hash = baseHash
                let commonCount = min(baseBuffer.count, probeBuffer.count)
                var i = 0
                while i < commonCount {
                    if baseBuffer[i] != probeBuffer[i] {
                        hash ^= contribution(at: i, baseBuffer[i])
                        hash ^= contribution(at: i, probeBuffer[i])
                    }
                    i += 1
                }
                while i < baseBuffer.count {
                    hash ^= contribution(at: i, baseBuffer[i])
                    i += 1
                }
                while i < probeBuffer.count {
                    hash ^= contribution(at: i, probeBuffer[i])
                    i += 1
                }
                return hash
            }
        }
    }

    /// Position-dependent hash contribution of a single element.
    /// Uses splitmix64 mixing for good avalanche with XOR combination.
    static func contribution(at position: Int, _ value: ChoiceSequenceValue) -> UInt64 {
        var bits: UInt64 = switch value {
        case let .value(v):
            v.choice.bitPattern64 ^ (tagBits(v.choice.tag) << 48)
        case .sequence(true, validRange: _, isLengthExplicit: true):
            1
        case .sequence(true, validRange: _, isLengthExplicit: false):
            2
        case .sequence(false, validRange: _, isLengthExplicit: true):
            3
        case .sequence(false, validRange: _, isLengthExplicit: false):
            4
        case .group(true):
            5
        case .group(false):
            6
        case .bind(true):
            8
        case .bind(false):
            9
        case let .branch(b):
            b.id ^ 0xDEAD_BEEF_CAFE_BABE
        case .just:
            7
        }
        bits ^= UInt64(position) &* 0x9E37_79B9_7F4A_7C15
        bits = (bits ^ (bits >> 30)) &* 0xBF58_476D_1CE4_E5B9
        bits = (bits ^ (bits >> 27)) &* 0x94D0_49BB_1331_11EB
        bits ^= bits >> 31
        return bits
    }

    private static func tagBits(_ tag: TypeTag) -> UInt64 {
        switch tag {
        case .uint: 0
        case .uint64: 1
        case .uint32: 2
        case .uint16: 3
        case .uint8: 4
        case .int: 5
        case .int64: 6
        case .int32: 7
        case .int16: 8
        case .int8: 9
        case .double: 10
        case .float: 11
        case .float16: 12
        case .date: 13
        case .bits: 14
        case .character: 15
        case .depthControl: 16
        case .laneControl: 17
        }
    }
}
