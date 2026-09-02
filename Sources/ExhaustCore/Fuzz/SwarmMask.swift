// Swarm generation for the mutation phase: per-epoch branch masking.
//
// A uniform branch mix statistically suppresses value shapes that need a run of one kind — the canonical case is a stack that never fills while `pop` and `clear` stay in the mix (Groce et al., "Swarm Testing", ISSTA 2012). Fuzz therefore runs in swarm epochs: within one epoch a deterministic mask disallows a random subset of each pick site's branches, and mutated children have their disallowed branch selections pivoted to allowed ones before materialization. Diversity comes from the epoch schedule, not any single mask.
//
// The mask lives beside the choice sequence, derived from the root seed, never inside it. Whole-run replay reproduces the epoch schedule for free, and `.exact` re-materialization of any individual entry reads its branch selections from the sequence itself, so reproducers never need the mask. The mask is applied as a sequence rewrite in the mutation layer — the guided materializer then follows the pivoted branch and PRNG-fills its content, exactly as it does for the existing branch-pivot operator — so no interpreter or materializer code paths change.

/// One epoch's branch mask, derived entirely from the epoch seed.
package struct SwarmMask: Sendable {
    /// The epoch's identity; per-site masks derive from it and the site fingerprint, so the mask needs no site registry and is independent of encounter order.
    package let epochSeed: UInt64

    package init(epochSeed: UInt64) {
        self.epochSeed = epochSeed
    }

    /// The mask for one derivation index: the root seed and index mix through SplitMix64 so consecutive indices share no structure. The activated path passes a per-attempt index (a fresh mask every attempt); the binary path passes an epoch index (`mutationAttempts / swarmEpochAttempts`).
    package static func forIndex(_ index: Int, rootSeed: UInt64) -> SwarmMask {
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

    /// Returns a per-branch activation weight in [0, 1) at a pick site, or nil when the site is unweighted. The weights are the activated-swarm generalisation of ``allowedBranches(fingerprint:branchCount:)``: where the binary mask gives each branch a weight of 0 or 1, this gives a continuous weight, so mutated children reach command mixes at specific ratios rather than binary include-or-exclude subsets.
    ///
    /// Every masked site is weighted every epoch — the weights themselves provide the roaming, so there is no half-of-sites-uniform skip. Sites with fingerprint 0 stay unweighted for the same reason they stay unmasked: an unfingerprinted site cannot be distinguished from any other, and one accidental shared weighting is worse than none.
    package func branchWeights(fingerprint: UInt64, branchCount: UInt64) -> [Double]? {
        guard fingerprint != 0, branchCount > 1 else {
            return nil
        }
        var siteState = Self.splitMix64(epochSeed ^ fingerprint)
        var weights: [Double] = []
        weights.reserveCapacity(Int(branchCount))
        for _ in 0 ..< branchCount {
            siteState = Self.splitMix64(siteState)
            weights.append(Self.unit(siteState))
        }
        return weights
    }

    /// Appends the per-branch activation weights of a pick site to `weights`, or appends nothing and returns false when the site is unweighted. The storage form of ``branchWeights(fingerprint:branchCount:)``, so the activated rewrite can keep every site's weights in one reusable buffer.
    private func appendBranchWeights(fingerprint: UInt64, branchCount: UInt64, into weights: inout [Double]) -> Bool {
        guard fingerprint != 0, branchCount > 1 else {
            return false
        }
        var siteState = Self.splitMix64(epochSeed ^ fingerprint)
        for _ in 0 ..< branchCount {
            siteState = Self.splitMix64(siteState)
            weights.append(Self.unit(siteState))
        }
        return true
    }

    /// Reusable storage for ``applyActivated(to:scratch:prng:)``.
    ///
    /// A mask is derived per candidate, so nothing carries over between calls but the capacity: a per-call dictionary and one `[Double]` per pick site were 1% of a mutation-phase run in allocation alone. Sites are kept in a short list searched linearly, because a sequence repeats a handful of fingerprints many times.
    package struct ActivationScratch {
        fileprivate var sites: [(fingerprint: UInt64, offset: Int, count: Int, total: Double)] = []
        fileprivate var weights: [Double] = []

        package init() {}
    }

    /// Rewrites branch selections toward each site's activation weights, allocating scratch for the call. See ``applyActivated(to:scratch:prng:)``.
    package func applyActivated(to sequence: ChoiceSequence, prng: inout Xoshiro256) -> ChoiceSequence {
        var scratch = ActivationScratch()
        return applyActivated(to: sequence, scratch: &scratch, prng: &prng)
    }

    /// Rewrites branch selections toward each site's activation weights: a selected branch is pivoted away with probability `1 - weight`, and the replacement is drawn from the weighted distribution over branches.
    ///
    /// A low-activation branch is pivoted away most of the time, so it appears rarely in the mix; a high-activation branch usually survives untouched. Over a sequence this pulls the branch mix toward the epoch's activation ratios — the mixes a binary mask cannot reach, because it can only include or exclude a branch, never thin it. The activation weights are deterministic from the epoch seed; the pivot rolls and weighted draws consume the run PRNG, so the sampling replays under a pinned seed.
    package func applyActivated(
        to sequence: ChoiceSequence,
        scratch: inout ActivationScratch,
        prng: inout Xoshiro256
    ) -> ChoiceSequence {
        var result = sequence
        // All entries from one pick site share a fingerprint, so a sequence typically repeats a handful of fingerprints many times. Weights are deterministic from the fingerprint, so memoize them and their sum for the call. The PRNG is untouched, so a pinned seed still replays.
        scratch.sites.removeAll(keepingCapacity: true)
        scratch.weights.removeAll(keepingCapacity: true)
        for index in result.indices {
            guard case let .branch(branch) = result[index] else {
                continue
            }
            var siteIndex = -1
            var searchIndex = 0
            while searchIndex < scratch.sites.count {
                if scratch.sites[searchIndex].fingerprint == branch.fingerprint {
                    siteIndex = searchIndex
                    break
                }
                searchIndex += 1
            }
            if siteIndex < 0 {
                let offset = scratch.weights.count
                guard appendBranchWeights(
                    fingerprint: branch.fingerprint,
                    branchCount: branch.branchCount,
                    into: &scratch.weights
                ) else {
                    continue
                }
                var total = 0.0
                for weightIndex in offset ..< scratch.weights.count {
                    total += scratch.weights[weightIndex]
                }
                scratch.sites.append((
                    fingerprint: branch.fingerprint,
                    offset: offset,
                    count: scratch.weights.count - offset,
                    total: total
                ))
                siteIndex = scratch.sites.count - 1
            }
            let site = scratch.sites[siteIndex]
            // An out-of-range id (a resumed persistence document is not validated on this path) is left untouched rather than trapping, mirroring how ``apply(to:prng:)`` skips a selection its allowed set cannot contain.
            guard Int(branch.id) < site.count else {
                continue
            }
            guard Self.unit(prng.next()) >= scratch.weights[site.offset + Int(branch.id)] else {
                continue
            }
            let replacement = Self.weightedBranch(
                scratch.weights,
                offset: site.offset,
                count: site.count,
                total: site.total,
                prng: &prng
            )
            result[index] = .branch(.init(
                id: replacement,
                branchCount: branch.branchCount,
                fingerprint: branch.fingerprint
            ))
        }
        return result
    }

    /// Draws a branch identifier from the weighted distribution held at `weights[offset ..< offset + count]`, falling back to a uniform draw when every weight is near zero. `total` is the pre-summed weight, passed by the caller so a sequence that repeats a site does not re-sum its ring per entry.
    private static func weightedBranch(
        _ weights: [Double],
        offset: Int,
        count: Int,
        total: Double,
        prng: inout Xoshiro256
    ) -> UInt64 {
        guard total > 0 else {
            return prng.next(upperBound: UInt64(count))
        }
        var remaining = unit(prng.next()) * total
        for index in 0 ..< count {
            remaining -= weights[offset + index]
            if remaining < 0 {
                return UInt64(index)
            }
        }
        return UInt64(count - 1)
    }

    /// One uniform draw in [0, 1) from a 64-bit value (its top 53 bits).
    private static func unit(_ value: UInt64) -> Double {
        Double(value >> 11) / Double(1 << 53)
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
