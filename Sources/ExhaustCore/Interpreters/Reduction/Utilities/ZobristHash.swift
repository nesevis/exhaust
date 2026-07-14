//
//  ZobristHash.swift
//  Exhaust
//
//  Created by Chris Kolbu on 15/3/2026.
//

/// Zobrist hashing utilities for ``ChoiceSequence`` duplicate detection during reduction.
///
/// Computes position-dependent XOR hashes that support O(1) incremental updates when single elements change. Used by reducer code for PRNG seeding and ``CandidateRejectionCache`` lookups.
package enum ZobristHash {
    /// Computes a deterministic hash from marker structure, numeric bit patterns, and selected branch identifiers.
    ///
    /// The initial count contribution distinguishes sequences whose trailing entry would otherwise contribute zero. Each entry is mixed once by kind and payload, then again by position, so different entry kinds do not share the deliberately simple contribution namespace used by ``hash(of:)``.
    package static func operativeHash(of sequence: ChoiceSequence) -> UInt64 {
        sequence.withUnsafeBufferPointer { buffer in
            var hash = mix(UInt64(buffer.count), at: buffer.count)
            var index = 0
            while index < buffer.count {
                hash ^= operativeContribution(at: index, buffer[index])
                index += 1
            }
            return hash
        }
    }

    /// Computes a Zobrist hash: XOR of position-dependent contributions for each element.
    /// Enables O(1) incremental updates when single elements change.
    package static func hash(of sequence: ChoiceSequence) -> UInt64 {
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

    /// Position-dependent hash contribution of a raw `UInt64` value.
    @inline(__always)
    package static func mix(_ value: UInt64, at position: Int) -> UInt64 {
        var bits = value ^ (UInt64(position) &* 0x9E37_79B9_7F4A_7C15)
        bits = (bits ^ (bits >> 30)) &* 0xBF58_476D_1CE4_E5B9
        bits = (bits ^ (bits >> 27)) &* 0x94D0_49BB_1331_11EB
        bits ^= bits >> 31
        return bits
    }

    /// Position-dependent hash contribution of a single element.
    static func contribution(at position: Int, _ value: ChoiceSequenceValue) -> UInt64 {
        let bits: UInt64 = switch value {
            case let .value(v):
                v.choice.bitPattern64 ^ (UInt64(v.choice.tag.discriminator) << 48)
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
        return mix(bits, at: position)
    }

    /// Computes one position-dependent contribution without generator-derived metadata.
    private static func operativeContribution(
        at position: Int,
        _ value: ChoiceSequenceValue
    ) -> UInt64 {
        let identity = switch value {
            case let .value(value):
                mix(value.choice.bitPattern64, at: 0)
            case .sequence(true, validRange: _, isLengthExplicit: _):
                mix(0, at: 1)
            case .sequence(false, validRange: _, isLengthExplicit: _):
                mix(0, at: 2)
            case .group(true):
                mix(0, at: 3)
            case .group(false):
                mix(0, at: 4)
            case .bind(true):
                mix(0, at: 5)
            case .bind(false):
                mix(0, at: 6)
            case .just:
                mix(0, at: 7)
            case let .branch(branch):
                mix(branch.id, at: 8)
        }
        return mix(identity, at: position)
    }
}
