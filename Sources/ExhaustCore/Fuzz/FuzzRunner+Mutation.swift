// Candidate production for the fuzz loop: arm selection and the swarm rewrite.

/// Per-draw mutable state the mutation loop sets and ``FuzzRunner/evaluate(_:)`` reads: reseed ranges for the lineage row, the one-per-draw reward flag, and the draw's evaluation cost. Grouped so the loop resets one struct per draw instead of four fields.
package struct MutationDrawState {
    /// Provenance of the failing candidate, set by evaluate and consumed by recordLineage.
    package var pendingLineage: FuzzFailureLineage.Provenance?
    /// Reseed spans of the mutation child under evaluation, for the lineage row.
    package var reseedRanges: [ClosedRange<Int>] = []
    /// Whether the bandit has been rewarded for this draw. A draw that yields several children (an enumeration) rewards at most once.
    package var rewarded = false
    /// Evaluations this draw spends: 1 for every arm but an enumeration, which spends one per alternative.
    package var cost = 1

    package mutating func reset(cost: Int) {
        pendingLineage = nil
        reseedRanges = []
        rewarded = false
        self.cost = cost
    }
}

/// One produced candidate and the accounting the bandit needs to credit it on admission.
package struct MutationDraw {
    package let candidate: ChoiceSequence
    /// The arm to credit, which is the arm drawn unless its operator missed and a band absorbed the attempt.
    package let armsMask: MutationArmSet
    /// The eligible set the arm was drawn from, so the bandit can compute the conditional probability at reward time instead of on every draw.
    package let eligible: MutationArmSet
    /// Spans of the candidate the materialiser should draw fresh, from a value reseed. Empty for every other arm; the candidate itself is the parent's sequence when this is not.
    package var reseedRanges: [ClosedRange<Int>] = []
    /// Further candidates from the same draw, evaluated after `candidate` under the same arm: the rest of a small-domain enumeration. Empty for every other arm.
    package var alternatives: [ChoiceSequence] = []
    /// Whether the draw is a small-domain enumeration, whose children are deliberate single-site edits and skip the swarm rewrite. Set for every enumeration, a two-value domain's single child included, since `alternatives` is empty for that one.
    package var isEnumeration = false
}

extension FuzzRunner {
    // MARK: - Candidate Production

    /// Produces one mutated candidate from `parent`. Two steps in sequence: one arm drawn from the eligible inventory, then the swarm rewrite of the result's branch selections.
    package func nextCandidate(from parent: CorpusEntry, parentIndex: Int) -> MutationDraw {
        let draw = inventoryCandidate(from: parent, parentIndex: parentIndex)
        // An enumeration is a deliberate single-site edit whose children differ from the parent at exactly that site; a swarm rewrite of their branch selections would take that away and make the batch incomparable.
        if draw.isEnumeration {
            swarmDerivationIndex += 1
            return draw
        }
        switch configuration.experiments.swarmMode {
            case .off:
                swarmDerivationIndex += 1
                return draw
            case .activated:
                // Per-candidate weights, so the activation distribution roams every produced candidate rather than every epoch.
                let mask = SwarmMask.forIndex(swarmDerivationIndex, rootSeed: configuration.seed)
                swarmDerivationIndex += 1
                return MutationDraw(
                    candidate: mask.applyActivated(to: draw.candidate, scratch: &swarmScratch, prng: &prng),
                    armsMask: draw.armsMask,
                    eligible: draw.eligible,
                    reseedRanges: draw.reseedRanges
                )
        }
    }

    /// The arms this parent's draw may choose from: the operators that can fire on it, narrowed further by the operators the generator has been shown to admit.
    package func eligibleSet(for parent: CorpusEntry, parentIndex: Int) -> MutationArmSet {
        if configuration.experiments.armEligibility {
            return eligibleArms(parent: parent, parentIndex: parentIndex)
        }
        guard configuration.experiments.armAdmissibility, let sightedArms else {
            return .all
        }
        return sightedArms
    }

    /// Selects the arm for one candidate: the bandit, or the fixed distribution, drawn from the eligible set.
    package func drawArm(eligible: MutationArmSet) -> MutationArm {
        if configuration.experiments.banditBands {
            return bandit.pick(random: randomUnit(), eligible: eligible) ?? .high
        }
        return fixedDistributionArm(eligible: eligible)
    }

    /// Re-materializes one admitted sequence with its picks expanded and unions the operators the resulting structure admits into the run's repertoire.
    ///
    /// The corpus stores trees materialized without picks, so an entry's own graph describes the path it took: an unselected branch carries no subtree, and an operator that only applies inside one looks inapplicable. Expanding the picks gives every alternative full structure, so what ``MutationArmRepertoire`` reports is the generator's repertoire rather than one draw's.
    ///
    /// The repertoire only grows, and every source of evidence is positive. An operator the structure admits is a property of the generator, not of the entry that revealed it, so a later entry whose own shape lacks it proves nothing and cannot retract it. Absence is never proof either: one entry's expansion does not descend into picks nested inside the alternatives it expanded, nor into a bind's bound region, so an operator can be reachable and go unsighted here. What the admitting parent can target is folded in for the same reason, and read here rather than at the draw so it costs one lookup per inspection rather than one per candidate. Until the first inspection the whole inventory stays open.
    ///
    /// Sampled at admissions rather than per draw, and only once admissions have slowed to ``FuzzTunables/armAdmissibilitySlowdown`` attempts apart. When the admitted entry already has a full tree (pick-materialised, from ``FuzzCorpus/upgradeToFullTree(at:fullTree:)``), its graph is read directly and no re-materialisation is needed. The fallback re-materialisation covers entries that were admitted without a full tree.
    package func noteStructuralAdmissibility(of _: ChoiceSequence, parentIndex: Int?, admittedIndex: Int) {
        if let sightedArms, sightedArms.intersection(enabledArms) == enabledArms {
            return
        }
        let gap = counts.totalAttempts - attemptsAtPreviousAdmission
        attemptsAtPreviousAdmission = counts.totalAttempts
        guard gap >= FuzzTunables.armAdmissibilitySlowdown else {
            return
        }
        if let parentIndex, corpus.entries.indices.contains(parentIndex), sightedArms != nil {
            let parent = corpus.entries[parentIndex]
            sightedArms = sightedArms?.union(eligibleArms(parent: parent, parentIndex: parentIndex))
        }
        if let targets = corpus.entries[admittedIndex].mutationTargets {
            sightedArms = (sightedArms ?? .bands).union(MutationArmRepertoire.sighted(in: targets.graph))
            return
        }
        let graph = ChoiceGraphBuilder.build(from: corpus.entries[admittedIndex].tree)
        sightedArms = (sightedArms ?? .bands).union(MutationArmRepertoire.sighted(in: graph))
    }

    /// The arms whose operators can fire on this parent, as a bit set of ``MutationArm`` raw values.
    ///
    /// Each precondition is the operator's own first guard. The structural ones are cached on the parent's ``MutationTargets`` at admission, so the set costs one union plus the two corpus-dependent checks, and the donor search is skipped outright when the crossover arm is not in the inventory. What it cannot predict is the second guard of the sibling-span operators, that a group's cached position ranges still fit the candidate — that is staleness rather than applicability, and it is why gating cannot drive `swap` and `shuffle` misses to zero.
    ///
    /// The three bands are unconditionally eligible. ``FuzzMutator/mutate(_:intensity:layout:prng:)`` falls back within and across them, so a band has no shape it can fail on: the medium band's branch pivot deletes a block when the sequence carries no branch marker, and the low band hands off to it when there are no values to perturb. Gating them on the shape they prefer would remove a working operator, and on a generator with no pick site it would remove the only arm that duplicates or replaces a block.
    private func eligibleArms(parent: CorpusEntry, parentIndex: Int) -> MutationArmSet {
        var eligible = MutationArmSet.bands
        let layout = parent.mutationLayout
        if FuzzTunables.spliceEnabled, layout?.hasBindRegion == true, corpus.parentIndices.count > 1 {
            eligible.insert(.splice)
        }
        guard let targets = corpus.mutationTargets(forParentAt: parentIndex) else {
            return eligible
        }
        eligible = eligible.union(targets.structuralArms)
        if enabledArms.contains(.typedCrossover), targets.hasCrossoverDonor(corpus: corpus, parentIndex: parentIndex) {
            eligible.insert(.typedCrossover)
        }
        return eligible
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
    private func inventoryCandidate(from parent: CorpusEntry, parentIndex: Int) -> MutationDraw {
        let layout = parent.mutationLayout
        corpus.noteCandidateDrawn(fromParentAt: parentIndex)
        let eligible = eligibleSet(for: parent, parentIndex: parentIndex)
        let arm = drawArm(eligible: eligible)
        counts.mutationArms.recordDraw(arm: arm)
        var candidate = parent.sequence
        var reseedRanges: [ClosedRange<Int>] = []
        var alternatives: [ChoiceSequence] = []
        var isEnumeration = false
        switch arm {
            case .smallDomainEnumeration:
                if let targets = corpus.mutationTargets(forParentAt: parentIndex),
                   let enumeration = FuzzMutator.enumerateSmallDomain(candidate, targets: targets, prng: &prng)
                {
                    candidate = enumeration.children[0]
                    alternatives = Array(enumeration.children.dropFirst())
                    isEnumeration = true
                    corpus.markEnumerated(siteIndex: enumeration.siteIndex, forParentAt: parentIndex)
                }
            case .valueReseed:
                if let targets = corpus.mutationTargets(forParentAt: parentIndex),
                   let ranges = FuzzMutator.valueReseed(candidate, targets: targets, prng: &prng)
                {
                    reseedRanges = ranges
                }
            case .suffixReseed:
                if let targets = corpus.mutationTargets(forParentAt: parentIndex),
                   let cut = FuzzMutator.suffixReseed(candidate, targets: targets, prng: &prng)
                {
                    candidate = cut.candidate
                    reseedRanges = cut.reseedRanges
                }
            case .low:
                candidate = FuzzMutator.mutate(candidate, intensity: .low, layout: layout, prng: &prng)
            case .medium:
                candidate = FuzzMutator.mutate(candidate, intensity: .medium, layout: layout, prng: &prng)
            case .high:
                candidate = FuzzMutator.mutate(candidate, intensity: .high, prng: &prng)
            case .swap, .shuffle, .move, .lockstepDelta, .twinSplice, .typedCrossover, .elementDeletion, .elementDuplication, .runDeletion, .runDuplication, .runCopy, .elementTransplant:
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
        if candidate != parent.sequence || reseedRanges.isEmpty == false {
            return MutationDraw(
                candidate: candidate,
                armsMask: MutationArmSet(arm),
                eligible: eligible,
                reseedRanges: reseedRanges,
                alternatives: alternatives,
                isEnumeration: isEnumeration
            )
        }
        counts.mutationArms.recordMiss(arm: arm)
        let intensityDraw = prng.next(upperBound: UInt64(MutationIntensity.allCases.count))
        let intensity = MutationIntensity.allCases[Int(intensityDraw)]
        let band = MutationArm(intensity: intensity)
        return MutationDraw(
            candidate: FuzzMutator.mutate(candidate, intensity: intensity, prng: &prng),
            armsMask: MutationArmSet(band),
            eligible: eligible
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
            case .elementDeletion:
                return FuzzMutator.deleteSequenceElement(candidate, targets: targets, prng: &prng)
            case .elementDuplication:
                return FuzzMutator.duplicateSequenceElement(candidate, targets: targets, prng: &prng)
            case .runDeletion:
                return FuzzMutator.deleteElementRun(candidate, targets: targets, prng: &prng)
            case .runDuplication:
                return FuzzMutator.duplicateElementRun(candidate, targets: targets, prng: &prng)
            case .runCopy:
                return FuzzMutator.copyElementRun(candidate, targets: targets, prng: &prng)
            case .elementTransplant:
                // Copy or move at even odds: the same arm, since both need the same pair of sequences and differ only in whether the donor keeps its run.
                let mode: FuzzMutator.TransplantMode = prng.next(upperBound: 2) == 0 ? .copy : .move
                return FuzzMutator.transplantElementRun(candidate, targets: targets, mode: mode, prng: &prng)
            case .low, .medium, .high, .splice, .valueReseed, .suffixReseed, .smallDomainEnumeration:
                return nil
        }
    }

    /// The fixed operator distribution for arm draws without the bandit: splice at its fixed probability while ``FuzzTunables/spliceEnabled`` holds, otherwise a uniform draw over the remaining eligible inventory (the three bands, plus the arms the `graphMutation` and `pairMutation` knobs add).
    ///
    /// The splice draw is consumed whether or not splice is eligible or enabled, so the PRNG stream advances the same amount per call and a gated run and an ungated one stay comparable attempt for attempt.
    private func fixedDistributionArm(eligible: MutationArmSet) -> MutationArm {
        let spliceDraw = randomUnit()
        if FuzzTunables.spliceEnabled, eligible.contains(.splice), spliceDraw < FuzzTunables.spliceProbability {
            return .splice
        }
        if eligible == .all, fixedDrawArms.isEmpty == false {
            return fixedDrawArms[Int(prng.next(upperBound: UInt64(fixedDrawArms.count)))]
        }
        var eligibleCount = 0
        for arm in fixedDrawArms where eligible.contains(arm) {
            eligibleCount += 1
        }
        guard eligibleCount > 0 else {
            return .high
        }
        var offset = Int(prng.next(upperBound: UInt64(eligibleCount)))
        for arm in fixedDrawArms where eligible.contains(arm) {
            if offset == 0 {
                return arm
            }
            offset -= 1
        }
        return .high
    }
}
