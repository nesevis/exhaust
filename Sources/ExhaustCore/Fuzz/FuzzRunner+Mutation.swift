// Candidate production for the fuzz loop: arm selection and the swarm rewrite.

extension FuzzRunner {
    // MARK: - Candidate Production

    /// Produces one mutated candidate from `parent` plus the bitmask of the ``MutationArm`` that shaped it (for bandit credit on admission). Two steps in sequence: one arm drawn from the enabled inventory, then the swarm rewrite of the result's branch selections.
    func nextCandidate(from parent: CorpusEntry, parentIndex: Int) -> (candidate: ChoiceSequence, armsMask: UInt32) {
        var (candidate, armsMask) = inventoryCandidate(from: parent, parentIndex: parentIndex)
        switch configuration.experiments.swarmMode {
            case .off:
                break
            case .activated:
                // Per-candidate weights, so the activation distribution roams every produced candidate rather than every epoch.
                let mask = SwarmMask.forIndex(swarmDerivationIndex, rootSeed: configuration.seed)
                candidate = mask.applyActivated(to: candidate, scratch: &swarmScratch, prng: &prng)
        }
        swarmDerivationIndex += 1
        return (candidate, armsMask)
    }

    /// Draws one splice donor uniformly from the parent domain.
    ///
    /// The parent domain rather than the whole corpus because it is the set with cached layouts to splice through; a discovery-tier entry carries none. Requires two entries so a donor other than the recipient can exist; consumes one draw either way, so the stream shape does not depend on the domain's size.
    private func drawSpliceDonor() -> CorpusEntry? {
        let domain = corpus.parentIndices
        guard domain.count > 1 else {
            return nil
        }
        return corpus.entries[domain[Int(prng.next(upperBound: UInt64(domain.count)))]]
    }

    /// The inventory mutation path: one child from one operator, drawn from the bandit's distribution or, with the bandit off, the fixed one over the enabled inventory.
    ///
    /// One operator per child, never a stack. Exhaust's band operators are each already multi-perturbation (a low step moves up to three values, a high step corrupts a quarter of the sequence), and composing several per child was measured on `DeepParser` (2026-07-11) as neutral-to-worse: AFL-depth stacks destroyed parent structure outright (deep-fault discovery 4/20 versus 20/20, throughput −42%), and shallower stacks were worse on attempts-to-fault. A single operator also keeps the bandit's reward honest, since the arm credited is the arm that produced the child.
    private func inventoryCandidate(from parent: CorpusEntry, parentIndex: Int) -> (candidate: ChoiceSequence, armsMask: UInt32) {
        let experiments = configuration.experiments
        let layout = parent.mutationLayout
        let arm = experiments.banditBands ? bandit.pick(random: randomUnit()) : fixedDistributionArm()
        var candidate = parent.sequence
        switch arm {
            case .low:
                candidate = FuzzMutator.mutate(candidate, intensity: .low, layout: layout, prng: &prng)
            case .medium:
                candidate = FuzzMutator.mutate(candidate, intensity: .medium, layout: layout, prng: &prng)
            case .high:
                candidate = FuzzMutator.mutate(candidate, intensity: .high, prng: &prng)
            case .swap, .shuffle, .move, .lockstepDelta, .twinSplice, .typedCrossover:
                if let targeted = graphArmCandidate(arm, candidate, parent: parent, parentIndex: parentIndex) {
                    candidate = targeted
                }
            case .splice:
                if let donor = drawSpliceDonor(),
                   donor.hash != parent.hash,
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
        if candidate != parent.sequence {
            return (candidate, 1 << UInt32(arm.rawValue))
        }
        // The arm found nothing to do (no usable bind region or donor, no targetable group, a no-op band step) and the corpus would reject the duplicate. Fall back to one band mutation so the attempt always explores; the band is credited, not the arm that missed.
        let intensityDraw = prng.next(upperBound: UInt64(MutationIntensity.allCases.count))
        let intensity = MutationIntensity.allCases[Int(intensityDraw)]
        return (
            FuzzMutator.mutate(candidate, intensity: intensity, prng: &prng),
            1 << UInt32(MutationArm(intensity: intensity).rawValue)
        )
    }

    /// Applies one graph-targeted operator to the candidate, or nil when the parent carries no targeting tables (a discovery-tier parent) or the operator found nothing to target. The tables are built on the first draw that reaches here.
    private func graphArmCandidate(
        _ arm: MutationArm,
        _ candidate: ChoiceSequence,
        parent: CorpusEntry,
        parentIndex: Int
    ) -> ChoiceSequence? {
        guard let targets = corpus.mutationTargets(forParentAt: parentIndex) else {
            return nil
        }
        switch arm {
            case .swap:
                return FuzzMutator.swapSiblingSpans(candidate, targets: targets, prng: &prng)
            case .shuffle:
                return FuzzMutator.shuffleSiblingSpans(candidate, targets: targets, prng: &prng)
            case .move:
                return FuzzMutator.moveSiblingSpan(candidate, targets: targets, prng: &prng)
            case .lockstepDelta:
                return FuzzMutator.lockstepDelta(candidate, targets: targets, prng: &prng)
            case .twinSplice:
                return FuzzMutator.twinSplice(candidate, targets: targets, prng: &prng)
            case .typedCrossover:
                return FuzzMutator.typedCrossover(
                    candidate,
                    parentHash: parent.hash,
                    targets: targets,
                    corpus: corpus,
                    prng: &prng
                )
            case .low, .medium, .high, .splice:
                return nil
        }
    }

    /// The fixed operator distribution for arm draws without the bandit: splice at its fixed probability, otherwise a uniform draw over the remaining enabled inventory (the three bands, plus the arms the `graphMutation` and `pairMutation` knobs add).
    private func fixedDistributionArm() -> MutationArm {
        if randomUnit() < FuzzTunables.spliceProbability {
            return .splice
        }
        return fixedDrawArms[Int(prng.next(upperBound: UInt64(fixedDrawArms.count)))]
    }
}
