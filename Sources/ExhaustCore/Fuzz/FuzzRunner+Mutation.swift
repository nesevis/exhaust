// Candidate production for the fuzz loop: mutation strategy selection and the swarm rewrite.

extension FuzzRunner {
    // MARK: - Candidate Production

    /// Produces one mutated candidate from `parent` plus the bitmask of ``MutationArm``s that shaped it (for bandit credit on admission). Two orthogonal knobs, applied in sequence: the mutation strategy (legacy single-operator or composed experiment stack), then the swarm rewrite of the result's disallowed branch selections.
    func nextCandidate(from parent: CorpusEntry) -> (candidate: ChoiceSequence, armsMask: UInt32) {
        let experiments = configuration.experiments
        var (candidate, armsMask) = experiments.stackedMutation || experiments.banditBands
            || experiments.graphMutation || experiments.pairMutation
            ? composedCandidate(from: parent)
            : legacyCandidate(from: parent)
        switch experiments.swarmMode {
            case .off:
                break
            case .activated:
                // Per-candidate weights, so the activation distribution roams every produced candidate rather than every epoch.
                let mask = SwarmMask.forIndex(swarmDerivationIndex, rootSeed: configuration.seed)
                candidate = mask.applyActivated(to: candidate, prng: &prng)
            case .binary:
                let epoch = SwarmMask.forIndex(
                    swarmDerivationIndex / FuzzTunables.swarmEpochAttempts,
                    rootSeed: configuration.seed
                )
                candidate = epoch.apply(to: candidate, prng: &prng)
        }
        swarmDerivationIndex += 1
        return (candidate, armsMask)
    }

    /// The original single-operator mutation path, kept verbatim so knob-off runs replay identically under a pinned seed: usually an intensity-band mutation, occasionally a bind-boundary splice with a random donor.
    private func legacyCandidate(from parent: CorpusEntry) -> (candidate: ChoiceSequence, armsMask: UInt32) {
        if randomUnit() < FuzzTunables.spliceProbability, corpus.entries.count > 1 {
            let donorIndex = Int(prng.next(upperBound: UInt64(corpus.entries.count)))
            let donor = corpus.entries[donorIndex]
            if donor.hash != parent.hash,
               let spliced = FuzzMutator.splice(
                   recipient: parent.sequence,
                   donor: donor.sequence,
                   recipientLayout: parent.mutationLayout,
                   donorLayout: donor.mutationLayout,
                   prng: &prng
               )
            {
                return (spliced, 1 << UInt32(MutationArm.splice.rawValue))
            }
        }
        let intensityDraw = prng.next(upperBound: UInt64(MutationIntensity.allCases.count))
        let intensity = MutationIntensity.allCases[Int(intensityDraw)]
        return (
            FuzzMutator.mutate(
                parent.sequence,
                intensity: intensity,
                layout: parent.mutationLayout,
                prng: &prng
            ),
            1 << UInt32(MutationArm(intensity: intensity).rawValue)
        )
    }

    /// The experiment mutation path: one child composed from `stackedMutation`'s operator stack with each operator drawn from the bandit's distribution (or the legacy fixed one when only stacking is on).
    ///
    /// The stack draw is 2^0...2^2 ({1, 2, 4} operators), not AFL's 2^1...2^7: Exhaust's band operators are each already multi-perturbation (a low-band step moves up to three values, a high-band step corrupts a quarter of the sequence), and the AFL-depth stacks measured on `DeepParser` destroyed parent structure outright (deep-fault discovery 4/20 versus 20/20, throughput −42%).
    private func composedCandidate(from parent: CorpusEntry) -> (candidate: ChoiceSequence, armsMask: UInt32) {
        let experiments = configuration.experiments
        let stackSize = 1 << Int(prng.next(upperBound: 3))
        let stackCount = experiments.stackedMutation ? stackSize : 1
        var candidate = parent.sequence
        var armsMask: UInt32 = 0
        for mutationIndex in 0 ..< stackCount {
            let layout = mutationIndex == 0 ? parent.mutationLayout : nil
            let arm = experiments.banditBands ? bandit.pick(random: randomUnit()) : fixedDistributionArm()
            armsMask |= 1 << UInt32(arm.rawValue)
            switch arm {
                case .low:
                    candidate = FuzzMutator.mutate(
                        candidate, intensity: .low, layout: layout, prng: &prng
                    )
                case .medium:
                    candidate = FuzzMutator.mutate(
                        candidate, intensity: .medium, layout: layout, prng: &prng
                    )
                case .high:
                    candidate = FuzzMutator.mutate(candidate, intensity: .high, prng: &prng)
                case .swap:
                    guard let graph = parent.choiceGraph,
                          let swapped = FuzzMutator.swapSiblingSpans(
                              candidate,
                              scopes: parent.permutationScopes,
                              graph: graph,
                              prng: &prng
                          )
                    else {
                        continue
                    }
                    candidate = swapped
                case .shuffle:
                    guard let graph = parent.choiceGraph,
                          let shuffled = FuzzMutator.shuffleSiblingSpans(
                              candidate,
                              scopes: parent.permutationScopes,
                              graph: graph,
                              prng: &prng
                          )
                    else {
                        continue
                    }
                    candidate = shuffled
                case .move:
                    guard let graph = parent.choiceGraph,
                          let moved = FuzzMutator.moveSiblingSpan(
                              candidate,
                              scopes: parent.permutationScopes,
                              graph: graph,
                              prng: &prng
                          )
                    else {
                        continue
                    }
                    candidate = moved
                case .lockstepDelta:
                    guard let graph = parent.choiceGraph,
                          let tandem = parent.tandemScope,
                          let shifted = FuzzMutator.lockstepDelta(
                              candidate,
                              tandem: tandem,
                              graph: graph,
                              prng: &prng
                          )
                    else {
                        continue
                    }
                    candidate = shifted
                case .twinSplice:
                    guard let spliced = FuzzMutator.twinSplice(
                        candidate,
                        twinSpanGroups: parent.twinSpanGroups,
                        prng: &prng
                    ) else {
                        continue
                    }
                    candidate = spliced
                case .typedCrossover:
                    guard let graph = parent.choiceGraph,
                          let crossed = FuzzMutator.typedCrossover(
                              candidate,
                              parentHash: parent.hash,
                              graph: graph,
                              corpus: corpus,
                              prng: &prng
                          )
                    else {
                        continue
                    }
                    candidate = crossed
                case .valueWalk, .regionSweep:
                    // Unreachable from the bandit draw and the fixed distribution (campaigns dispatch at parent level), kept for switch exhaustiveness.
                    continue
                case .splice:
                    guard corpus.entries.count > 1 else {
                        continue
                    }
                    let donorIndex = Int(prng.next(upperBound: UInt64(corpus.entries.count)))
                    let donor = corpus.entries[donorIndex]
                    // Skip self-splices against the current candidate, not the parent as the legacy path does: mid-stack the candidate has already drifted, so a parent-donor splice is genuine recombination.
                    if donor.sequence != candidate,
                       let spliced = FuzzMutator.splice(
                           recipient: candidate,
                           donor: donor.sequence,
                           recipientLayout: layout,
                           donorLayout: donor.mutationLayout,
                           prng: &prng
                       )
                    {
                        candidate = spliced
                    }
            }
        }
        if candidate == parent.sequence {
            // Nothing perturbed the parent (splice arms found no usable bind region or donor, or a band mutation was a no-op on this sequence), and the corpus would reject the duplicate. Fall back to one band mutation so the attempt always explores.
            let intensityDraw = prng.next(upperBound: UInt64(MutationIntensity.allCases.count))
            let intensity = MutationIntensity.allCases[Int(intensityDraw)]
            armsMask |= 1 << UInt32(MutationArm(intensity: intensity).rawValue)
            candidate = FuzzMutator.mutate(
                candidate,
                intensity: intensity,
                prng: &prng
            )
        }
        return (candidate, armsMask)
    }

    /// The fixed operator distribution for arm draws without the bandit: splice at its fixed probability, otherwise a uniform draw over the remaining enabled inventory (the three bands, plus the arms the `graphMutation` and `pairMutation` knobs add).
    private func fixedDistributionArm() -> MutationArm {
        if randomUnit() < FuzzTunables.spliceProbability {
            return .splice
        }
        return fixedDrawArms[Int(prng.next(upperBound: UInt64(fixedDrawArms.count)))]
    }
}
