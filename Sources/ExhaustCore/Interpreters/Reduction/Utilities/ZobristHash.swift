//
//  ZobristHash.swift
//  Exhaust
//
//  Created by Chris Kolbu on 15/3/2026.
//

/// Zobrist hashing utilities for ``ChoiceSequence`` duplicate detection during reduction.
///
/// Computes position-dependent XOR hashes that support O(1) incremental updates when single
/// elements change. Used by reducer code for PRNG seeding and ``ReducerCache`` lookups.
public enum ZobristHash {
    /// Computes a Zobrist hash: XOR of position-dependent contributions for each element.
    /// Enables O(1) incremental updates when single elements change.
    static func hash(of sequence: ChoiceSequence) -> UInt64 {
        var hash: UInt64 = 0
        // while-loop: avoiding IteratorProtocol overhead in debug builds.
        var i = 0
        while i < sequence.count {
            hash ^= contribution(at: i, sequence[i])
            i += 1
        }
        return hash
    }

    /// Computes the hash of `probe` incrementally from a cached `baseHash` and `baseSequence`.
    ///
    /// Scans for differing positions between `baseSequence` and `probe`, then XOR-updates the
    /// base hash with removed and added contributions. Avoids splitmix64 mixing for unchanged
    /// elements. For k changed positions out of n total, cost is O(n) comparison + O(k) mixing
    /// instead of O(n) mixing.
    static func incrementalHash(
        baseHash: UInt64,
        baseSequence: ChoiceSequence,
        probe: ChoiceSequence
    ) -> UInt64 {
        var hash = baseHash
        let commonCount = min(baseSequence.count, probe.count)
        var i = 0
        while i < commonCount {
            if baseSequence[i] != probe[i] {
                hash ^= contribution(at: i, baseSequence[i])
                hash ^= contribution(at: i, probe[i])
            }
            i += 1
        }
        // Tail of base (probe is shorter): remove trailing contributions.
        while i < baseSequence.count {
            hash ^= contribution(at: i, baseSequence[i])
            i += 1
        }
        // Tail of probe (probe is longer): add trailing contributions.
        while i < probe.count {
            hash ^= contribution(at: i, probe[i])
            i += 1
        }
        return hash
    }

    /// Position-dependent hash contribution of a single element.
    /// Uses splitmix64 mixing for good avalanche with XOR combination.
    static func contribution(at position: Int, _ value: ChoiceSequenceValue) -> UInt64 {
        var bits: UInt64 = switch value {
        case let .value(v):
            v.choice.bitPattern64 ^ (tagBits(v.choice.tag) << 48)
        case let .reduced(v):
            v.choice.bitPattern64 ^ (tagBits(v.choice.tag) << 48) ^ 0xFF00_FF00_FF00_FF00
        case .sequence(true, isLengthExplicit: true):
            1
        case .sequence(true, isLengthExplicit: false):
            2
        case .sequence(false, isLengthExplicit: true):
            3
        case .sequence(false, isLengthExplicit: false):
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
        }
    }
}
