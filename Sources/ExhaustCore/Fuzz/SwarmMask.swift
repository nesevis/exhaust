// Swarm generation for the mutation phase: per-epoch branch masking.
//
// A uniform branch mix statistically suppresses value shapes that need a run of one kind — the canonical case is a stack that never fills while `pop` and `clear` stay in the mix (Groce et al., "Swarm Testing", ISSTA 2012). Fuzz therefore runs in swarm epochs: within one epoch a deterministic mask disallows a random subset of each pick site's branches, and mutated children have their disallowed branch selections pivoted to allowed ones before materialization. Diversity comes from the epoch schedule, not any single mask.
//
// The mask lives beside the choice sequence, derived from the root seed, never inside it. Whole-run replay reproduces the epoch schedule for free, and `.exact` re-materialization of any individual entry reads its branch selections from the sequence itself, so reproducers never need the mask. The mask is applied as a sequence rewrite in the mutation layer — the guided materializer then follows the pivoted branch and PRNG-fills its content, exactly as it does for the existing branch-pivot operator — so no interpreter or materializer code paths change.

/// One epoch's branch mask, derived entirely from the epoch seed. See the file header for the seam decision.
package struct SwarmMask: Sendable {
    /// The epoch's identity; per-site masks derive from it and the site fingerprint, so the mask needs no site registry and is independent of encounter order.
    package let epochSeed: UInt64

    package init(epochSeed: UInt64) {
        self.epochSeed = epochSeed
    }

    /// The mask for one run epoch: the root seed and epoch index mix through SplitMix64 so consecutive epochs share no structure.
    package static func forEpoch(index: Int, rootSeed: UInt64) -> SwarmMask {
        SwarmMask(epochSeed: splitMix64(rootSeed &+ 0x9E37_79B9_7F4A_7C15 &* UInt64(index &+ 1)))
    }

    /// Returns the allowed branch identifiers at a pick site, or nil when the site is unmasked this epoch.
    ///
    /// Half of all sites stay uniform each epoch, and each branch of a masked site survives with probability ½ (at least one always survives). Sites with fingerprint 0 are never masked — without a fingerprint the site cannot be told apart from every other unfingerprinted site, and one accidental shared mask across unrelated picks is worse than no mask.
    package func allowedBranches(fingerprint: UInt64, branchCount: UInt64) -> [UInt64]? {
        guard fingerprint != 0, branchCount > 1 else {
            return nil
        }
        var siteState = Self.splitMix64(epochSeed ^ fingerprint)
        // Site masked at all this epoch?
        guard siteState & 1 == 1 else {
            return nil
        }
        var allowed: [UInt64] = []
        allowed.reserveCapacity(Int(branchCount))
        for branch in 0 ..< branchCount {
            siteState = Self.splitMix64(siteState)
            if siteState & 1 == 1 {
                allowed.append(branch)
            }
        }
        if allowed.isEmpty {
            // Every branch masked: keep one, chosen by the same deterministic stream.
            allowed.append(Self.splitMix64(siteState) % branchCount)
        }
        if allowed.count == Int(branchCount) {
            return nil
        }
        return allowed
    }

    /// Rewrites every disallowed branch selection in `sequence` to an allowed one drawn from the run PRNG, leaving allowed selections and all other entries untouched.
    ///
    /// The pivoted branch's content resolves through the guided materializer's PRNG fallback, the same degradation path the branch-pivot mutation already exercises.
    package func apply(to sequence: ChoiceSequence, prng: inout Xoshiro256) -> ChoiceSequence {
        var result = sequence
        for index in result.indices {
            guard case let .branch(branch) = result[index],
                  let allowed = allowedBranches(fingerprint: branch.fingerprint, branchCount: branch.branchCount),
                  allowed.contains(branch.id) == false
            else {
                continue
            }
            let replacement = allowed[Int(prng.next(upperBound: UInt64(allowed.count)))]
            result[index] = .branch(.init(
                id: replacement,
                branchCount: branch.branchCount,
                fingerprint: branch.fingerprint
            ))
        }
        return result
    }

    /// SplitMix64: the standard 64-bit finalizer, here the whole derivation chain from seed to per-site mask bits.
    private static func splitMix64(_ state: UInt64) -> UInt64 {
        var z = state &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
