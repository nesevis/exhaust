// Candidate production for the sprawl loop: mutation strategy selection and the swarm rewrite.

import ExhaustCore

extension SprawlRunner {
    // MARK: - Candidate Production

    /// Produces one mutated candidate from `parent` plus the bitmask of ``MutationArm``s that shaped it (for bandit credit on admission). Two orthogonal knobs, applied in sequence: the mutation strategy (legacy single-operator or composed experiment stack), then the swarm rewrite of the result's disallowed branch selections.
    func nextCandidate(from parent: CorpusEntry) -> (candidate: ChoiceSequence, armsMask: UInt8) {
        let experiments = configuration.experiments
        var (candidate, armsMask) = experiments.stackedMutation || experiments.banditBands
            ? composedCandidate(from: parent)
            : legacyCandidate(from: parent)
        if experiments.swarm {
            let epoch = SwarmMask.forEpoch(
                index: sprawlAttempts / SprawlTunables.swarmEpochAttempts,
                rootSeed: configuration.seed
            )
            candidate = epoch.apply(to: candidate, prng: &prng)
        }
        return (candidate, armsMask)
    }

    /// The original single-operator mutation path, kept verbatim so knob-off runs replay identically under a pinned seed: usually an intensity-band mutation, occasionally a bind-boundary splice with a random donor.
    private func legacyCandidate(from parent: CorpusEntry) -> (candidate: ChoiceSequence, armsMask: UInt8) {
        if randomUnit() < SprawlTunables.spliceProbability, corpus.entries.count > 1 {
            let donorIndex = Int(prng.next(upperBound: UInt64(corpus.entries.count)))
            let donor = corpus.entries[donorIndex]
            if donor.hash != parent.hash,
               let spliced = SprawlMutator.splice(recipient: parent.sequence, donor: donor.sequence, prng: &prng)
            {
                return (spliced, 1 << UInt8(MutationArm.splice.rawValue))
            }
        }
        let intensityDraw = prng.next(upperBound: UInt64(SprawlIntensity.allCases.count))
        let intensity = SprawlIntensity.allCases[Int(intensityDraw)]
        return (
            SprawlMutator.mutate(parent.sequence, intensity: intensity, prng: &prng),
            1 << UInt8(intensityDraw)
        )
    }

    /// The experiment mutation path: one child composed from `stackedMutation`'s operator stack with each operator drawn from the bandit's distribution (or the legacy fixed one when only stacking is on).
    ///
    /// The stack draw is 2^0...2^2 ({1, 2, 4} operators), not AFL's 2^1...2^7: Exhaust's band operators are each already multi-perturbation (a low-band step moves up to three values, a high-band step corrupts a quarter of the sequence), and the AFL-depth stacks measured on `DeepParser` destroyed parent structure outright (deep-fault discovery 4/20 versus 20/20, throughput −42%).
    private func composedCandidate(from parent: CorpusEntry) -> (candidate: ChoiceSequence, armsMask: UInt8) {
        let experiments = configuration.experiments
        let stackSize = 1 << Int(prng.next(upperBound: 3))
        let stackCount = experiments.stackedMutation ? stackSize : 1
        var candidate = parent.sequence
        var armsMask: UInt8 = 0
        for _ in 0 ..< stackCount {
            let arm = experiments.banditBands ? bandit.pick(random: randomUnit()) : fixedDistributionArm()
            armsMask |= 1 << UInt8(arm.rawValue)
            switch arm {
                case .low:
                    candidate = SprawlMutator.mutate(candidate, intensity: .low, prng: &prng)
                case .medium:
                    candidate = SprawlMutator.mutate(candidate, intensity: .medium, prng: &prng)
                case .high:
                    candidate = SprawlMutator.mutate(candidate, intensity: .high, prng: &prng)
                case .splice:
                    guard corpus.entries.count > 1 else {
                        continue
                    }
                    let donorIndex = Int(prng.next(upperBound: UInt64(corpus.entries.count)))
                    let donor = corpus.entries[donorIndex]
                    // Skip self-splices against the current candidate, not the parent as the legacy path does: mid-stack the candidate has already drifted, so a parent-donor splice is genuine recombination.
                    if donor.sequence != candidate,
                       let spliced = SprawlMutator.splice(recipient: candidate, donor: donor.sequence, prng: &prng)
                    {
                        candidate = spliced
                    }
            }
        }
        if candidate == parent.sequence {
            // Nothing perturbed the parent (splice arms found no usable bind region or donor, or a band mutation was a no-op on this sequence), and the corpus would reject the duplicate. Fall back to one band mutation so the attempt always explores.
            let intensityDraw = prng.next(upperBound: UInt64(SprawlIntensity.allCases.count))
            armsMask |= 1 << UInt8(intensityDraw)
            candidate = SprawlMutator.mutate(candidate, intensity: SprawlIntensity.allCases[Int(intensityDraw)], prng: &prng)
        }
        return (candidate, armsMask)
    }

    /// The legacy operator distribution (splice at its fixed probability, otherwise a uniform band) expressed as one draw, for the stacked-without-bandit arm.
    private func fixedDistributionArm() -> MutationArm {
        if randomUnit() < SprawlTunables.spliceProbability {
            return .splice
        }
        return MutationArm(rawValue: Int(prng.next(upperBound: 3))) ?? .low
    }
}
