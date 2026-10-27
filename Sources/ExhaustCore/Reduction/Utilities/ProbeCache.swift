/// Separates rejection evidence from incompatible decoding, admission, or ordering policies.
struct ProbeDecision {
    let isGuided: Bool
    let admission: DecoderAdmission
    let order: ReductionOrder

    init(isGuided: Bool, admission: DecoderAdmission = .standard, order: ReductionOrder = .notLarger) {
        self.isGuided = isGuided
        self.admission = admission
        self.order = order
    }

    init(_ selection: ReductionDecoder.Selection, order: ReductionOrder = .notLarger) {
        switch selection {
            case let .exact(_, admission):
                self.init(isGuided: false, admission: admission, order: order)
            case .guided:
                self.init(isGuided: true, order: order)
        }
    }
}

// MARK: - Probe Cache

/// Candidates whose decoding was not admitted, so an identical candidate is turned away before decoding.
///
/// Policy rejections are scoped to the decoder, admission, and ordering. Confirmed property passes are reusable across admissions and orderings. Guided results also depend on the incumbent unless a passing walk was determined entirely by its prefix. Keys are 64-bit Zobrist hashes, so a collision turns a candidate away as if it had been tried.
struct ProbeCache {
    private var keys: Set<UInt64> = []
    private var propertyPassKeys: Set<UInt64> = []
    private var prefixPropertyPassHashes: Set<UInt64> = []

    init() {}

    /// Includes the incumbent for guided decoding, whose fallback tree can change the recovered value. Exact rejections remain reusable as ordinary reduction lowers the incumbent.
    private func key(probeHash: UInt64, decision: ProbeDecision, incumbentHash: UInt64) -> UInt64 {
        let decisionKey = probeHash ^ Self.decisionSalt(decision)
        guard decision.isGuided else {
            return decisionKey
        }
        return decisionKey ^ Self.finalize(incumbentHash ^ Self.incumbentSeed)
    }

    /// Carries one lookup's complete decision context through decoding and recording. Construction always consults the cache, so callers cannot bypass its evidence-sharing rules with a raw key.
    struct Lookup {
        let probeHash: UInt64
        let decision: ProbeDecision
        let incumbentHash: UInt64
        let key: UInt64
        let isCached: Bool

        init(cache: ProbeCache, probeHash: UInt64, decision: ProbeDecision, incumbentHash: UInt64) {
            self.probeHash = probeHash
            self.decision = decision
            self.incumbentHash = incumbentHash
            key = cache.key(probeHash: probeHash, decision: decision, incumbentHash: incumbentHash)
            isCached = cache.rejects(probeHash: probeHash, decision: decision, incumbentHash: incumbentHash, key: key)
        }
    }

    /// A property pass is reusable under any admission or ordering for the same decoding context. Otherwise, a stricter ordering can reuse an ordinary rejection, but never the reverse: equal failures are admissible only to ordinary reduction.
    func lookup(probeHash: UInt64, decision: ProbeDecision, incumbentHash: UInt64) -> Lookup {
        Lookup(cache: self, probeHash: probeHash, decision: decision, incumbentHash: incumbentHash)
    }

    /// Records a rejected evaluation with exactly the context used for its lookup. A passing guided walk can cross incumbents only when `sources == .prefix`; membership alone would also admit fallback or unknown dependencies.
    mutating func record(_ lookup: Lookup, outcome: SequenceDecodingOutcome) {
        keys.insert(lookup.key)
        if case let .propertyPassed(_, sources) = outcome {
            propertyPassKeys.insert(propertyPassKey(
                probeHash: lookup.probeHash,
                isGuided: lookup.decision.isGuided,
                incumbentHash: lookup.incumbentHash
            ))
            if lookup.decision.isGuided, sources == .prefix {
                prefixPropertyPassHashes.insert(lookup.probeHash)
            }
        }
    }

    /// Checks prefix-certified passes before context-bound evidence. Strict recovery may reuse an ordinary rejection because it admits a subset of ordinary reduction's candidates.
    private func rejects(probeHash: UInt64, decision: ProbeDecision, incumbentHash: UInt64, key: UInt64) -> Bool {
        if decision.isGuided, prefixPropertyPassHashes.contains(probeHash) {
            return true
        }
        if keys.contains(key) || propertyPassKeys.contains(propertyPassKey(
            probeHash: probeHash,
            isGuided: decision.isGuided,
            incumbentHash: incumbentHash
        )) {
            return true
        }
        if case .strictlySmaller = decision.order {
            let ordinary = ProbeDecision(isGuided: decision.isGuided, admission: decision.admission, order: .notLarger)
            let ordinaryKey = self.key(probeHash: probeHash, decision: ordinary, incumbentHash: incumbentHash)
            return keys.contains(ordinaryKey)
        }
        return false
    }

    /// Starts a new evidence lifetime, discarding both policy rejections and reusable property passes.
    mutating func removeAll() {
        keys.removeAll(keepingCapacity: true)
        propertyPassKeys.removeAll(keepingCapacity: true)
        prefixPropertyPassHashes.removeAll(keepingCapacity: true)
    }

    // MARK: - Helpers

    /// Encodes decoding and ordering policy before mixing it into the key. Admission also hashes its leaf positions separately.
    private struct DecisionFlags: OptionSet {
        let rawValue: UInt64

        static let guided = Self(rawValue: 1 << 0)
        static let strictlySmaller = Self(rawValue: 1 << 1)
        static let unordered = Self(rawValue: 1 << 2)
    }

    private static let decisionSeed: UInt64 = 0x5851_F42D_4C95_7F2D
    private static let incumbentSeed: UInt64 = 0x2545_F491_4F6C_DD1D

    /// Omits admission and ordering because an observed property pass rejects the decoded value under either policy. Guided decoding still needs its incumbent context.
    private func propertyPassKey(probeHash: UInt64, isGuided: Bool, incumbentHash: UInt64) -> UInt64 {
        let decoding = ProbeDecision(isGuided: isGuided)
        return key(probeHash: probeHash, decision: decoding, incumbentHash: incumbentHash)
    }

    private static func finalize(_ value: UInt64) -> UInt64 {
        ZobristHash.mix(value, at: 0)
    }

    /// Includes the admission's leaf positions in the hash so numeric checks on different coordinates contribute distinct decision context.
    private static func decisionSalt(_ decision: ProbeDecision) -> UInt64 {
        var flags: DecisionFlags = []
        if decision.isGuided {
            flags.insert(.guided)
        }
        switch decision.order {
            case .notLarger:
                break
            case .strictlySmaller:
                flags.insert(.strictlySmaller)
            case .unordered:
                flags.insert(.unordered)
        }
        var salt = finalize(flags.rawValue &+ decisionSeed)
        switch decision.admission {
            case .standard:
                break
            case let .numericPair(pair):
                salt ^= finalize(0x10 &+ decisionSeed)
                salt ^= finalize(UInt64(pair.source.position) &* Xoshiro256.goldenRatioConstant &+ 1)
                salt ^= finalize(UInt64(pair.sink.position) &* Xoshiro256.goldenRatioConstant &+ 2)
            case let .numericJoint(leaves):
                salt ^= finalize(0x20 &+ decisionSeed)
                for (index, leaf) in leaves.enumerated() {
                    salt ^= finalize(UInt64(leaf.position) &* Xoshiro256.goldenRatioConstant &+ UInt64(index) &+ 3)
                }
        }
        return salt
    }
}
