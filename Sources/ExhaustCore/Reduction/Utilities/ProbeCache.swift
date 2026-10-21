//
//  ProbeCache.swift
//  Exhaust
//

// MARK: - Probe Cache Keying

/// What a probe cache rejection is recorded against, beyond the candidate's hash.
enum ProbeCacheKeying: Sendable {
    /// The candidate's hash alone. A rejection under one decoder mode or admission answers for every other, and a guided rejection outlives the incumbent whose tree filled it.
    case sequence
    /// The hash, the decoder mode, whether shortlex is enforced, and the admission with its leaves. A rejection answers only for the same decision. Whether picks are materialized is left out: it decides how complete the recovered tree is, not whether the property fails.
    case decision
    /// As ``decision``, and a guided rejection is also tied to the incumbent whose tree filled the content the candidate left undetermined.
    case decisionAndIncumbent
}

/// How one candidate is decided, for keying its probe cache entry.
struct ProbeDecision {
    let isGuided: Bool
    let admission: DecoderAdmission

    init(isGuided: Bool, admission: DecoderAdmission = .standard) {
        self.isGuided = isGuided
        self.admission = admission
    }

    init(_ selection: ReductionDecoder.Selection) {
        switch selection {
            case let .exact(_, admission):
                self.init(isGuided: false, admission: admission)
            case .guided:
                self.init(isGuided: true)
        }
    }
}

// MARK: - Probe Cache

/// Candidates whose decoding was not admitted, so an identical candidate is turned away before decoding.
///
/// A hit is a claim that decoding the candidate again would repeat the recorded outcome. That claim needs the key to cover every input of the decision, and ``ProbeCacheKeying`` chooses how much of the decision is folded into the key. Keys are 64-bit Zobrist hashes, so a collision turns a candidate away as if it had been tried.
struct ProbeCache: ExpressibleByArrayLiteral {
    let keying: ProbeCacheKeying
    private var keys: Set<UInt64> = []

    init(keying: ProbeCacheKeying) {
        self.keying = keying
    }

    /// A cache under the default tuning's keying, holding `keys` as already rejected.
    init(arrayLiteral keys: UInt64...) {
        self.init(keying: ReductionTuning().probeCacheKeying)
        self.keys = Set(keys)
    }

    /// An empty cache with the same keying.
    var emptied: ProbeCache {
        ProbeCache(keying: keying)
    }

    /// The key a candidate with `probeHash`, decided as `decision` against the incumbent hashing to `incumbentHash`, is recorded under.
    func key(probeHash: UInt64, decision: ProbeDecision, incumbentHash: UInt64) -> UInt64 {
        switch keying {
            case .sequence:
                return probeHash
            case .decision:
                return probeHash ^ Self.decisionSalt(decision)
            case .decisionAndIncumbent:
                guard decision.isGuided else {
                    return probeHash ^ Self.decisionSalt(decision)
                }
                return probeHash ^ Self.decisionSalt(decision) ^ Self.finalize(incumbentHash ^ Self.incumbentSeed)
        }
    }

    func contains(_ key: UInt64) -> Bool {
        keys.contains(key)
    }

    mutating func insert(_ key: UInt64) {
        keys.insert(key)
    }

    mutating func removeAll() {
        keys.removeAll(keepingCapacity: true)
    }

    // MARK: - Helpers

    private static let decisionSeed: UInt64 = 0x5851_F42D_4C95_7F2D
    private static let incumbentSeed: UInt64 = 0x2545_F491_4F6C_DD1D

    private static func finalize(_ value: UInt64) -> UInt64 {
        ZobristHash.mix(value, at: 0)
    }

    /// Mixes the decision's flags and its admission's leaf positions, so two admissions that check different leaves never share a key.
    private static func decisionSalt(_ decision: ProbeDecision) -> UInt64 {
        var flags: UInt64 = 0
        if decision.isGuided {
            flags |= 1
        }
        var salt = finalize(flags &+ decisionSeed)
        switch decision.admission {
            case .standard:
                break
            case let .numericPair(pair):
                salt ^= finalize(0x10 &+ decisionSeed)
                salt ^= finalize(UInt64(pair.source.position) &* 0x9E37_79B9_7F4A_7C15 &+ 1)
                salt ^= finalize(UInt64(pair.sink.position) &* 0x9E37_79B9_7F4A_7C15 &+ 2)
            case let .numericJoint(leaves):
                salt ^= finalize(0x20 &+ decisionSeed)
                for (index, leaf) in leaves.enumerated() {
                    salt ^= finalize(UInt64(leaf.position) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(index) &+ 3)
                }
        }
        return salt
    }
}
