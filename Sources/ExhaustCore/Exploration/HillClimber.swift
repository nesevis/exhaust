//
//  HillClimber.swift
//  Exhaust
//

/// Result of a single hill-climbing pass on a seed.
public enum HillClimbResult<Output> {
    /// A property-violating value was discovered during climbing.
    case counterexample(value: Output, tree: ChoiceTree, probesUsed: Int)
    /// The seed was improved (higher scorer output).
    case improved(seed: Seed, output: Output, probesUsed: Int)
    /// No improvement found within budget.
    case unchanged(probesUsed: Int)
}

/// Hill climber inspired by Hypothesis's `Optimiser`.
///
/// Single backward loop over all sequence entries (values + branches), using `GuidedMaterializer` for each probe. Modify one entry in the flat sequence, replay the prefix, and let fresh PRNG choices fill in beyond the modification.
///
/// **Acceptance criterion** (from Hypothesis):
/// - Score improvement → accept
/// - Same score, sequence no longer → accept (lateral move to escape local optima)
/// - Score decrease → reject
public enum HillClimber {
    public static func climb<Output>(
        seed: Seed,
        gen: ReflectiveGenerator<Output>,
        scorer: (Output) -> Double,
        property: (Output) -> Bool,
        budget: Int,
        prng: inout Xoshiro256,
    ) -> HillClimbResult<Output> {
        var currentSequence = seed.sequence
        var probesUsed = 0

        // Local PRNG for probe seeds — derived from the seed's own data
        // so the external prng stream isn't perturbed by probe count.
        let probePRNGSeed = GenerationContext.runSeed(
            base: seed.generation &+ UInt64(seed.sequence.count),
            runIndex: UInt64(bitPattern: Int64(seed.fitness.bitPattern)),
        )
        var probePRNG = Xoshiro256(seed: probePRNGSeed)

        // Materialize the seed via GuidedMaterializer to get baseline
        guard case let .success(baselineValue, _, _) = GuidedMaterializer.materialize(
            gen, prefix: currentSequence, seed: probePRNG.next()
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
                var currentBP = v.choice.bitPattern64
                let validRange = v.validRange
                let isRangeExplicit = v.isRangeExplicit

                for direction in [true, false] {
                    guard probesUsed < budget else { break }

                    var foundCounterexample: (value: Output, tree: ChoiceTree)?
                    var didAccept = false

                    let _ = AdaptiveProbe.findInteger { (k: UInt64) -> Bool in
                        guard k > 0 else { return true }
                        guard probesUsed < budget else { return false }
                        guard k <= 1 << 20 else { return false }

                        let newBP: UInt64
                        if direction {
                            guard UInt64.max - k >= currentBP else { return false }
                            newBP = currentBP + k
                        } else {
                            guard currentBP >= k else { return false }
                            newBP = currentBP - k
                        }

                        if let validRange, isRangeExplicit, !validRange.contains(newBP) {
                            return false
                        }

                        let newChoice = ChoiceValue(
                            choiceTag.makeConvertible(bitPattern64: newBP),
                            tag: choiceTag,
                        )
                        let newEntry = ChoiceSequenceValue.value(.init(
                            choice: newChoice,
                            validRange: validRange,
                            isRangeExplicit: isRangeExplicit,
                        ))

                        var probe = currentSequence
                        probe[i] = newEntry

                        guard case let .success(value, sequence, tree) = GuidedMaterializer.materialize(
                            gen, prefix: probe, seed: probePRNG.next()
                        ) else {
                            probesUsed += 1
                            return false
                        }
                        probesUsed += 1

                        if property(value) == false {
                            let ceTree = reflectOrFallback(gen: gen, value: value, fallback: tree)
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
                            currentBP = newBP
                            didAccept = true
                            // Return false to stop findInteger — we've accepted and
                            // need to restart the outer loop with the new sequence.
                            return false
                        }
                        return false
                    }

                    if let ce = foundCounterexample {
                        return .counterexample(value: ce.value, tree: ce.tree, probesUsed: probesUsed)
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
                for idx in stride(from: shuffled.count - 1, through: 1, by: -1) {
                    let j = Int(prng.next(upperBound: UInt64(idx + 1)))
                    shuffled.swapAt(idx, j)
                }

                var branchAccepted = false
                for altID in shuffled {
                    guard probesUsed < budget else { break }

                    var probe = currentSequence
                    probe[i] = .branch(.init(id: altID, validIDs: b.validIDs))

                    guard case let .success(value, sequence, tree) = GuidedMaterializer.materialize(
                        gen, prefix: probe, seed: probePRNG.next()
                    ) else {
                        probesUsed += 1
                        continue
                    }
                    probesUsed += 1

                    if property(value) == false {
                        let ceTree = reflectOrFallback(gen: gen, value: value, fallback: tree)
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
                generation: seed.generation,
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
        currentLength: Int,
    ) -> Bool {
        if newScore > currentScore { return true }
        if newScore == currentScore, newLength <= currentLength { return true }
        return false
    }

    /// Reflect a value to get a consistent tree, falling back to the provided tree.
    private static func reflectOrFallback<Output>(
        gen: ReflectiveGenerator<Output>,
        value: Output,
        fallback: ChoiceTree,
    ) -> ChoiceTree {
        (try? Interpreters.reflect(gen, with: value)) ?? fallback
    }
}
