//
//  HillClimber.swift
//  Exhaust
//

/// Result of a single hill-climbing pass on a seed.
package enum HillClimbResult<Output> {
    /// A property-violating value was discovered during climbing.
    case counterexample(value: Output, tree: ChoiceTree, probesUsed: Int)
    /// The seed was improved (higher scorer output).
    case improved(seed: Seed, output: Output, probesUsed: Int)
    /// No improvement found within budget.
    case unchanged(probesUsed: Int)
}

/// Hill climber inspired by Hypothesis's `Optimiser`.
///
/// Single backward loop over all sequence entries (values + branches), using ``ReductionMaterializer`` for each probe. Modify one entry in the flat sequence, replay the prefix, and let fresh PRNG choices fill in beyond the modification.
///
/// **Acceptance criterion** (from Hypothesis):
/// - Score improvement → accept
/// - Same score, sequence no longer → accept (lateral move to escape local optima)
/// - Score decrease → reject
///
/// ## fingerprint Stability and Branch Ping-Pong
///
/// The branch handler (line ~173) swaps the selected alternative at a pick site and materializes the result. The lateral-move acceptance criterion ("same score, no growth") can cause infinite ping-pong between two branch alternatives when siteIDs are stable across materializations:
///
/// 1. Position `i` has branch id=A. Swap to B → same score, same length → lateral accept → restart from end.
/// 2. Walk back to position `i`. Now has id=B. Swap to A → same score → lateral accept → restart.
/// 3. Repeat forever. Each cycle costs probes but never exhausts budget on deep generators.
///
/// With PRNG siteIDs (current default), each materialization produces different random siteIDs in the choice tree, making the round-trip non-deterministic. The sequences are never exactly identical, breaking the cycle by luck. With fingerprint-based siteIDs (stable, deterministic), the round-trip IS deterministic and the ping-pong is exact.
///
/// **Attempted fix**: restricting branch acceptance to strict score improvement (`score > currentScore`, no lateral moves). This prevents ping-pong but disables lateral exploration — branch alternatives that restructure the tree without improving score can no longer be accepted. The impact on exploration quality is unknown.
///
/// **Deeper issue**: even with strict branch acceptance, fingerprint-based siteIDs cause a 36x slowdown (50ms → 1800ms on `exploreWithScorerFindsDeepBSTs`). The cause is likely in the ``NoveltyTracker``'s branch-path fingerprinting: stable siteIDs collapse the tier-1 novelty signal for structurally similar seeds, reducing seed pool diversity and forcing the explorer to exhaust its budget. This is a fundamental tension — stable siteIDs help the reducer (branch promotion, sibling swap) but hurt the explorer (novelty detection).
///
/// **Possible resolution**: split fingerprint strategies — PRNG at generation time (VACTI) for exploration diversity, fingerprint + depth augmentation at materialization time (``ReductionMaterializer``) for reducer stability. The reducer re-materializes before branch encoders run, so generation-time siteIDs don't affect reduction. This split has not been implemented.
package enum HillClimber {
    /// Performs one hill-climbing pass on `seed`, probing mutations up to `budget` times and returning an improved seed, a counterexample, or unchanged.
    public static func climb<Output>(
        seed: Seed,
        gen: ReflectiveGenerator<Output>,
        scorer: (Output) -> Double,
        property: (Output) -> Bool,
        budget: Int,
        prng: inout Xoshiro256
    ) -> HillClimbResult<Output> {
        var currentSequence = seed.sequence
        var probesUsed = 0

        // Local PRNG for probe seeds — derived from the seed's own data
        // so the external prng stream isn't perturbed by probe count.
        let probePRNGSeed = GenerationContext.runSeed(
            base: seed.generation &+ UInt64(seed.sequence.count),
            runIndex: UInt64(bitPattern: Int64(seed.fitness.bitPattern))
        )
        var probePRNG = Xoshiro256(seed: probePRNGSeed)

        // Materialize the seed to get baseline
        guard case let .success(baselineValue, _, _) = Materializer.materialize(
            gen, prefix: currentSequence, mode: .guided(seed: probePRNG.next(), fallbackTree: nil)
        ) else {
            return .unchanged(probesUsed: 0)
        }
        probesUsed += 1
        var currentScore = scorer(baselineValue)
        var bestOutput = baselineValue
        var improved = false

        // Single backward loop over all entries
        var i = currentSequence.count - 1
        outer: while i >= 0, probesUsed < budget {
            let entry = currentSequence[i]

            switch entry {
            // Skip structural markers
            case .group, .bind, .sequence, .just:
                i -= 1
                continue

            case .value, .reduced:
                guard let v = entry.value else {
                    i -= 1
                    continue
                }

                let choiceTag = v.choice.tag
                var currentBitPattern = v.choice.bitPattern64
                let validRange = v.validRange
                let isRangeExplicit = v.isRangeExplicit

                for direction in [true, false] {
                    guard probesUsed < budget else { break }

                    var foundCounterexample: (value: Output, tree: ChoiceTree)?
                    var didAccept = false

                    _ = AdaptiveProbe.findInteger { (k: UInt64) -> Bool in
                        guard k > 0 else { return true }
                        guard probesUsed < budget else { return false }
                        guard k <= 1 << 20 else { return false }

                        let newBitPattern: UInt64
                        if direction {
                            guard UInt64.max - k >= currentBitPattern else { return false }
                            newBitPattern = currentBitPattern + k
                        } else {
                            guard currentBitPattern >= k else { return false }
                            newBitPattern = currentBitPattern - k
                        }

                        if let validRange, isRangeExplicit, !validRange.contains(newBitPattern) {
                            return false
                        }

                        let newChoice = ChoiceValue(
                            choiceTag.makeConvertible(bitPattern64: newBitPattern),
                            tag: choiceTag
                        )
                        let newEntry = ChoiceSequenceValue.value(.init(
                            choice: newChoice,
                            validRange: validRange,
                            isRangeExplicit: isRangeExplicit
                        ))

                        var probe = currentSequence
                        probe[i] = newEntry

                        let probeResult = Materializer.materialize(
                            gen,
                            prefix: probe,
                            mode: .guided(
                                seed: probePRNG.next(),
                                fallbackTree: nil
                            )
                        )
                        guard case let .success(value, freshTree, _) = probeResult else {
                            probesUsed += 1
                            return false
                        }
                        probesUsed += 1
                        let sequence = ChoiceSequence(freshTree)

                        if property(value) == false {
                            let ceTree = reflectOrFallback(
                                gen: gen,
                                value: value,
                                fallback: freshTree
                            )
                            foundCounterexample = (value, ceTree)
                            return false
                        }

                        let score = scorer(value)
                        if accept(newScore: score, currentScore: currentScore,
                                  newLength: sequence.count, currentLength: currentSequence.count)
                        {
                            if score > currentScore { improved = true }
                            currentScore = score
                            bestOutput = value
                            currentSequence = sequence
                            currentBitPattern = newBitPattern
                            didAccept = true
                            // Return false to stop findInteger — we've accepted and
                            // need to restart the outer loop with the new sequence.
                            return false
                        }
                        return false
                    }

                    if let ce = foundCounterexample {
                        return .counterexample(
                            value: ce.value,
                            tree: ce.tree,
                            probesUsed: probesUsed
                        )
                    }

                    if didAccept {
                        // Restart backward scan from end of the (possibly new) sequence
                        i = currentSequence.count - 1
                        continue outer
                    }
                }

                i -= 1

            case let .branch(b):
                let alternatives = b.validIDs.filter { $0 != b.id }
                guard !alternatives.isEmpty else {
                    i -= 1
                    continue
                }

                var shuffled = alternatives
                for i in stride(from: shuffled.count - 1, through: 1, by: -1) {
                    let j = Int(prng.next(upperBound: UInt64(i + 1)))
                    shuffled.swapAt(i, j)
                }

                var branchAccepted = false
                for altID in shuffled {
                    guard probesUsed < budget else { break }

                    var probe = currentSequence
                    probe[i] = .branch(.init(id: altID, validIDs: b.validIDs))

                    let branchResult = Materializer.materialize(
                        gen,
                        prefix: probe,
                        mode: .guided(
                            seed: probePRNG.next(),
                            fallbackTree: nil
                        )
                    )
                    guard case let .success(value, freshTree, _) = branchResult else {
                        probesUsed += 1
                        continue
                    }
                    probesUsed += 1
                    let sequence = ChoiceSequence(freshTree)

                    if property(value) == false {
                        let ceTree = reflectOrFallback(gen: gen, value: value, fallback: freshTree)
                        return .counterexample(value: value, tree: ceTree, probesUsed: probesUsed)
                    }

                    let score = scorer(value)
                    if accept(newScore: score, currentScore: currentScore,
                              newLength: sequence.count, currentLength: currentSequence.count)
                    {
                        if score > currentScore { improved = true }
                        currentScore = score
                        bestOutput = value
                        currentSequence = sequence
                        branchAccepted = true
                        break
                    }
                }

                if branchAccepted {
                    i = currentSequence.count - 1
                    continue outer
                }
                i -= 1
            }
        }

        if improved {
            let currentTree = reflectOrFallback(gen: gen, value: bestOutput, fallback: seed.tree)
            let newSeed = Seed(
                sequence: currentSequence,
                tree: currentTree,
                noveltyScore: 0,
                fitness: currentScore,
                generation: seed.generation
            )
            return .improved(seed: newSeed, output: bestOutput, probesUsed: probesUsed)
        }
        return .unchanged(probesUsed: probesUsed)
    }

    // MARK: - Private

    /// Hypothesis-style acceptance: improve score, or lateral move (same score, no growth).
    private static func accept(
        newScore: Double,
        currentScore: Double,
        newLength: Int,
        currentLength: Int
    ) -> Bool {
        if newScore > currentScore { return true }
        if newScore == currentScore, newLength <= currentLength { return true }
        return false
    }

    /// Reflect a value to get a consistent tree, falling back to the provided tree.
    private static func reflectOrFallback<Output>(
        gen: ReflectiveGenerator<Output>,
        value: Output,
        fallback: ChoiceTree
    ) -> ChoiceTree {
        (try? Interpreters.reflect(gen, with: value)) ?? fallback
    }
}
