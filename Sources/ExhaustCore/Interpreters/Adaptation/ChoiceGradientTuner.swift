//
//  ChoiceGradientTuner.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/2/2026.
//

import Foundation

/// Three-stage offline tuner for pick-heavy generators (BST, AVL, etc.).
///
/// Pure online CGS (`OnlineCGSInterpreter`) gives excellent *ranking* of choices —
/// it knows which picks lead to valid outputs — but it's expensive per-sample
/// (derivative evaluation at every site) and overcommits to the dominant winner,
/// quickly exhausting unique values. This tuner addresses both problems:
///
/// ## Stage 1: Online CGS warmup
///
/// Runs the generator through `OnlineCGSInterpreter` for a fixed number of warmup
/// passes, collecting per-site, per-choice fitness data into a `FitnessAccumulator`.
/// Unlike `GeneratorTuning.tune()` which samples each site independently, CGS
/// conditions on upstream choices via `DerivativeContext`, producing better weights
/// for recursive generators where the validity of a subtree depends on ancestors.
///
/// The warmup is the only expensive phase. All subsequent generation uses the cheap
/// `ValueAndChoiceTreeInterpreter` with the baked weights — same quality signal,
/// ~100x cheaper per sample.
///
/// ## Stage 2: Fitness-shared weight baking
///
/// Raw CGS fitness data assigns weights proportional to how often each choice led
/// to valid outputs. If choice A succeeds 90% and choice B only 10%, the raw
/// weights are 9:1. The generator then hammers choice A and quickly exhausts its
/// unique values, while choice B — which leads to a different, equally valid region
/// of the output space — is starved.
///
/// The default `.fitnessSharing` strategy redistributes weight via niche-count
/// sharing: `weight_i = fitness_i / (1 + N × share_i)` where `share_i` is the
/// choice's proportion of total fitness at the site. Dominant choices get a heavy
/// divisor; minority choices get a light one. This preserves the ranking (choice A
/// still outweighs choice B) while flattening the distribution toward the tail.
///
/// On AVL benchmarks, fitness sharing makes CGS-baked weights 2x faster than raw
/// `totalFitness` baking and 3x faster than `Adaptive` for time-to-100 unique
/// valid trees.
///
/// ## Stage 3: Adaptive smoothing
///
/// After baking, per-site entropy analysis identifies bottleneck sites — picks
/// where one choice dominates — and applies higher temperature there to prevent
/// any single site from becoming a chokepoint. Well-distributed sites keep low
/// temperature to preserve the tuned distribution. This is the same
/// `GeneratorTuning.smoothAdaptively` used by the probe-based tuner.
///
/// ## Result
///
/// A statically-tuned generator suitable for `ValueAndChoiceTreeInterpreter`.
/// The three stages compose: CGS provides the right ranking, fitness sharing
/// prevents overcommitment to the winner, and adaptive smoothing ensures no
/// single site strangles diversity.
@_spi(ExhaustInternal) public enum ChoiceGradientTuner<FinalOutput> {
    /// How baked pick weights are derived from the accumulated fitness data.
    ///
    /// All strategies use the same CGS warmup data; they differ only in how
    /// that data is converted to static pick weights.
    @_spi(ExhaustInternal) public enum WeightingStrategy {
        /// Raw cumulative fitness: weight = sum of fitness scores across warmup runs.
        /// Fast to compute but produces peaky weights that lock onto the dominant
        /// cluster, limiting diversity at high unique counts.
        /// - Note: Not used in production. Retained for benchmarking against
        ///   `.fitnessSharing`; consistently 2x slower on AVL.
        case totalFitness

        /// Validity rate: weight = (fitness / observations) × 10000.
        /// Normalizes across sites regardless of sample count, but still suffers
        /// from the same overcommitment to dominant choices as `totalFitness`.
        /// - Note: Not used in production. Retained for benchmarking; performs
        ///   similarly to `totalFitness`.
        case validityRate

        /// Niche-count fitness sharing: weight = fitness / (1 + N × share).
        /// Discounts dominant choices proportionally — a choice with 90% of the
        /// fitness gets a heavy divisor while a 10% choice gets a light one.
        /// Preserves the CGS ranking while redistributing weight to the tail.
        /// Default strategy; benchmarked as 2–3x faster than alternatives on
        /// BST and AVL time-to-unique workloads.
        case fitnessSharing

        /// UCB1 exploration bonus: weight = meanFitness + C × √(ln(N_total) / N_i).
        /// Adds an exploration bonus that decays as a choice is observed more,
        /// based on the multi-armed bandit UCB1 formula. Unobserved choices get
        /// maximum exploration bonus. Competitive with fitness sharing on BST;
        /// slightly slower on AVL.
        /// - Note: Not used in production. Retained as an alternative exploration
        ///   strategy; ties with `.fitnessSharing` on BST but ~20% slower on AVL.
        case ucb(explorationConstant: Double)
    }

    @_spi(ExhaustInternal) public static func tune(
        _ generator: ReflectiveGenerator<FinalOutput>,
        predicate: @escaping (FinalOutput) -> Bool,
        warmupRuns: UInt64 = 400,
        sampleCount: UInt64 = 20,
        seed: UInt64? = nil,
        weightingStrategy: WeightingStrategy = .fitnessSharing,
    ) throws -> ReflectiveGenerator<FinalOutput> {
        // Stage 0: Preprocess — subdivide sequence lengths into picks over subranges
        // so CGS can guide length decisions (chooseBits sites are opaque to CGS).
        // We bake into the *original* generator to preserve structural compatibility
        // with choice trees (needed for filter replay and shrinking).
        let subdivisionContext = SubdivisionContext()
        let subdivided = try subdivideSequenceLengths(generator, context: subdivisionContext)

        // Stage 1: Online CGS warmup — the only expensive phase. Runs the
        // subdivided generator through OnlineCGSInterpreter, collecting per-site,
        // per-choice fitness data conditioned on upstream choices. Values are
        // discarded; only the accumulated fitness data matters.
        //
        // Convergence detection (ψ-based early stopping): periodically check
        // if per-site weight shares have stabilized. When the maximum absolute
        // shift drops below 5%, further runs won't meaningfully change the
        // baked weights — stop early to save warmup cost.
        //
        // Adapted from the ψ₀ probability-mass tracking in:
        //   Lipkin et al., "Fast Controlled Generation from Language Models
        //   with Adaptive Weighted Rejection Sampling", COLM 2025.
        //   arXiv:2504.05410
        let accumulator = FitnessAccumulator()
        var iterator = OnlineCGSInterpreter(
            subdivided,
            predicate: predicate,
            sampleCount: sampleCount,
            seed: seed,
            maxRuns: warmupRuns,
            fitnessAccumulator: accumulator,
        )
        let minWarmupRuns: UInt64 = 40
        let convergenceCheckInterval: UInt64 = 20
        var completedRuns: UInt64 = 0
        while iterator.next() != nil {
            completedRuns += 1
            if completedRuns >= minWarmupRuns,
               completedRuns.isMultiple(of: convergenceCheckInterval),
               accumulator.hasConverged(threshold: 0.05)
            {
                break
            }
        }

        // Stage 2: Weight baking — convert accumulated fitness into static pick
        // weights using the chosen strategy. The default .fitnessSharing discounts
        // dominant choices via niche-count sharing so the generator doesn't lock
        // onto a narrow cluster. Synthesized subdivision pick IDs won't match
        // original picks (harmless); element-level data carries over correctly.
        let baked = bakeWeights(generator, from: accumulator, strategy: weightingStrategy)

        // Stage 3: Adaptive smoothing — per-site entropy analysis identifies
        // bottleneck sites (where one choice dominates) and applies higher
        // temperature there to prevent chokepoints, while leaving well-distributed
        // sites alone to preserve the tuned distribution.
        return GeneratorTuning.smoothAdaptively(baked, baseTemperature: 2.0, maxTemperature: 8.0)
    }

    /// Recursively walks the generator tree, replacing pick weights with
    /// accumulated fitness data from the online CGS tuning pass.
    private static func bakeWeights<Output>(
        _ gen: ReflectiveGenerator<Output>,
        from accumulator: FitnessAccumulator,
        strategy: WeightingStrategy,
    ) -> ReflectiveGenerator<Output> {
        switch gen {
        case .pure:
            return gen

        case let .impure(operation, continuation):
            switch operation {
            case let .pick(choices):
                var baked = ContiguousArray<ReflectiveOperation.PickTuple>()
                baked.reserveCapacity(choices.count)

                // Precompute for strategies that need cross-choice context
                let precomputedWeights: ContiguousArray<UInt64>? = switch strategy {
                case .fitnessSharing:
                    computeFitnessSharingWeights(choices: choices, accumulator: accumulator)
                case .ucb(let explorationConstant):
                    computeUCBWeights(choices: choices, accumulator: accumulator, explorationConstant: explorationConstant)
                default:
                    nil
                }

                for (index, choice) in choices.enumerated() {
                    let weight: UInt64
                    if let precomputed = precomputedWeights {
                        weight = precomputed[index]
                    } else {
                        let key = FitnessAccumulator.SiteChoiceKey(siteID: choice.siteID, choiceID: choice.id)
                        if let record = accumulator.records[key] {
                            switch strategy {
                            case .totalFitness:
                                weight = record.totalFitness
                            case .validityRate:
                                // Scale rate to integer: (fitness / observations) * 10000
                                let rate = record.observationCount > 0
                                    ? Double(record.totalFitness) / Double(record.observationCount)
                                    : 0
                                weight = UInt64(rate * 10000)
                            case .fitnessSharing, .ucb:
                                // Handled by precomputedWeights above
                                weight = choice.weight
                            }
                        } else {
                            weight = choice.weight
                        }
                    }
                    baked.append(ReflectiveOperation.PickTuple(
                        siteID: choice.siteID,
                        id: choice.id,
                        weight: Swift.max(1, weight),
                        generator: bakeWeights(choice.generator, from: accumulator, strategy: strategy),
                    ))
                }
                return .impure(operation: .pick(choices: baked), continuation: continuation)

            case let .zip(generators):
                let bakedGens = ContiguousArray(generators.map { bakeWeights($0, from: accumulator, strategy: strategy) })
                return .impure(operation: .zip(bakedGens), continuation: continuation)

            case let .sequence(lengthGen, elementGen):
                return .impure(
                    operation: .sequence(
                        length: bakeWeights(lengthGen, from: accumulator, strategy: strategy),
                        gen: bakeWeights(elementGen, from: accumulator, strategy: strategy),
                    ),
                    continuation: continuation,
                )

            case let .contramap(transform, next):
                return .impure(
                    operation: .contramap(transform: transform, next: bakeWeights(next, from: accumulator, strategy: strategy)),
                    continuation: continuation,
                )

            case let .prune(next):
                return .impure(
                    operation: .prune(next: bakeWeights(next, from: accumulator, strategy: strategy)),
                    continuation: continuation,
                )

            case let .resize(newSize, next):
                return .impure(
                    operation: .resize(newSize: newSize, next: bakeWeights(next, from: accumulator, strategy: strategy)),
                    continuation: continuation,
                )

            case let .filter(subGen, fingerprint, filterType, predicate):
                return .impure(
                    operation: .filter(
                        gen: bakeWeights(subGen, from: accumulator, strategy: strategy),
                        fingerprint: fingerprint,
                        filterType: filterType,
                        predicate: predicate,
                    ),
                    continuation: continuation,
                )

            case let .classify(subGen, fingerprint, classifiers):
                return .impure(
                    operation: .classify(
                        gen: bakeWeights(subGen, from: accumulator, strategy: strategy),
                        fingerprint: fingerprint,
                        classifiers: classifiers,
                    ),
                    continuation: continuation,
                )

            case let .unique(subGen, fingerprint, keyExtractor):
                return .impure(
                    operation: .unique(
                        gen: bakeWeights(subGen, from: accumulator, strategy: strategy),
                        fingerprint: fingerprint,
                        keyExtractor: keyExtractor,
                    ),
                    continuation: continuation,
                )

            case .chooseBits, .just, .getSize:
                return gen
            }
        }
    }

    // MARK: - Fitness Sharing

    /// Niche-count fitness sharing: prevents the generator from overcommitting
    /// to the dominant choice at each pick site.
    ///
    /// For each choice, `share_i = fitness_i / siteTotal` measures how much of
    /// the site's total fitness it accounts for. The niche count
    /// `1 + N × share_i` grows with dominance: a choice with 90% share among
    /// 4 choices gets divisor 1 + 4×0.9 = 4.6, while a 10% choice gets
    /// 1 + 4×0.1 = 1.4. Dividing raw fitness by the niche count compresses
    /// the ratio from 9:1 down to ~1.96:0.71 ≈ 2.7:1 — still favoring the
    /// winner, but giving the minority choice meaningful sampling probability.
    private static func computeFitnessSharingWeights(
        choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        accumulator: FitnessAccumulator,
    ) -> ContiguousArray<UInt64> {
        let count = choices.count
        var rawFitnesses = ContiguousArray<Double>()
        rawFitnesses.reserveCapacity(count)

        // Pass 1: gather raw fitnesses and site total
        var siteTotal: Double = 0
        for choice in choices {
            let key = FitnessAccumulator.SiteChoiceKey(siteID: choice.siteID, choiceID: choice.id)
            let fitness = accumulator.records[key].map { Double($0.totalFitness) } ?? 0
            rawFitnesses.append(fitness)
            siteTotal += fitness
        }

        // Pass 2: compute shared weights
        let n = Double(count)
        var weights = ContiguousArray<UInt64>()
        weights.reserveCapacity(count)

        for fitness in rawFitnesses {
            let share = siteTotal > 0 ? fitness / siteTotal : 1.0 / n
            let nicheCount = 1.0 + n * share
            let weight = (fitness / nicheCount) * 10000
            weights.append(UInt64(weight))
        }

        return weights
    }

    // MARK: - UCB Exploration Bonus

    /// UCB1 (Upper Confidence Bound) exploration bonus from multi-armed bandit
    /// literature. Each choice's weight is `meanFitness + C × √(ln(N) / n_i)`
    /// where `N` is total observations across all choices at the site and `n_i`
    /// is this choice's observation count. The exploration term decays as a
    /// choice is sampled more, naturally balancing exploitation of known-good
    /// choices with exploration of under-sampled ones. Unobserved choices get
    /// the maximum exploration bonus `C × √(ln(N))`.
    private static func computeUCBWeights(
        choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        accumulator: FitnessAccumulator,
        explorationConstant: Double,
    ) -> ContiguousArray<UInt64> {
        let count = choices.count

        // Gather per-choice stats and total site observations
        var totalSiteObservations: UInt64 = 0
        var records = ContiguousArray<FitnessAccumulator.FitnessRecord?>()
        records.reserveCapacity(count)
        for choice in choices {
            let key = FitnessAccumulator.SiteChoiceKey(siteID: choice.siteID, choiceID: choice.id)
            let record = accumulator.records[key]
            records.append(record)
            totalSiteObservations += record?.observationCount ?? 0
        }

        let logTotal = totalSiteObservations > 0 ? log(Double(totalSiteObservations)) : 0
        var weights = ContiguousArray<UInt64>()
        weights.reserveCapacity(count)

        for record in records {
            let ucbScore: Double
            if let record, record.observationCount > 0 {
                let meanFitness = Double(record.totalFitness) / Double(record.observationCount)
                let explorationBonus = explorationConstant * sqrt(logTotal / Double(record.observationCount))
                ucbScore = meanFitness + explorationBonus
            } else {
                // Unobserved choices get maximum exploration bonus
                ucbScore = explorationConstant * sqrt(logTotal)
            }
            weights.append(UInt64(ucbScore * 10000))
        }

        return weights
    }

    // MARK: - Sequence Length Subdivision

    private final class SubdivisionContext {
        var nextID: UInt64 = UInt64.max / 2
        let maxSize: UInt64
        init(maxSize: UInt64 = 100) { self.maxSize = maxSize }
        func makeID() -> UInt64 { defer { nextID &+= 1 }; return nextID }
    }

    /// Preprocessing pass that rewrites sequence operations by converting their
    /// length generators into picks over subranges. This makes the length decision
    /// CGS-guidable at O(S × 4 × N_avg) cost instead of the O(N² × S) cost of
    /// per-element derivative composition.
    private static func subdivideSequenceLengths<Output>(
        _ gen: ReflectiveGenerator<Output>,
        context: SubdivisionContext,
    ) throws -> ReflectiveGenerator<Output> {
        switch gen {
        case .pure:
            return gen

        case let .impure(operation, continuation):
            switch operation {
            case let .sequence(lengthGen, elementGen):
                // 1. Recurse into element generator first (subdivide nested sequences)
                let subdividedElement = try subdivideSequenceLengths(elementGen, context: context)

                // 2a. Check if length generator is a direct .chooseBits with range > 4
                if case let .impure(.chooseBits(lower, upper, tag, isRangeExplicit), lengthContinuation) = lengthGen {
                    let rangeSize = upper - lower + 1
                    if rangeSize > 4 {
                        let subrangeCount = Swift.min(4, Int(Swift.min(rangeSize, UInt64(Int.max))))
                        let subranges = (lower ... upper).split(into: subrangeCount)

                        var subrangeChoices = ContiguousArray<ReflectiveOperation.PickTuple>()
                        subrangeChoices.reserveCapacity(subranges.count)

                        for subrange in subranges {
                            let subLengthGen: ReflectiveGenerator<UInt64> = .impure(
                                operation: .chooseBits(
                                    min: subrange.lowerBound,
                                    max: subrange.upperBound,
                                    tag: tag,
                                    isRangeExplicit: isRangeExplicit,
                                ),
                                continuation: lengthContinuation,
                            )

                            let subSeqGen: ReflectiveGenerator<Any> = .impure(
                                operation: .sequence(length: subLengthGen, gen: subdividedElement),
                                continuation: { .pure($0) },
                            )

                            subrangeChoices.append(ReflectiveOperation.PickTuple(
                                siteID: context.makeID(),
                                id: context.makeID(),
                                weight: 1,
                                generator: subSeqGen,
                            ))
                        }

                        // Do NOT recurse into synthesized pick — inner generators are already subdivided
                        return .impure(
                            operation: .pick(choices: subrangeChoices),
                            continuation: continuation,
                        )
                    }
                }

                // 2b. Check if length generator is .getSize → continuation
                if case let .impure(.getSize, getSizeContinuation) = lengthGen {
                    let subranges = (0 ... context.maxSize).split(into: Swift.min(4, Int(context.maxSize + 1)))

                    var subrangeChoices = ContiguousArray<ReflectiveOperation.PickTuple>()
                    subrangeChoices.reserveCapacity(subranges.count)

                    for subrange in subranges {
                        let subSizeGen: ReflectiveGenerator<UInt64> = .impure(
                            operation: .chooseBits(
                                min: subrange.lowerBound,
                                max: subrange.upperBound,
                                tag: .uint64,
                                isRangeExplicit: false,
                            ),
                            continuation: { .pure($0 as! UInt64) },
                        )

                        let subSeqGen: ReflectiveGenerator<Any> = try .impure(
                            operation: .sequence(
                                length: subSizeGen.bind(getSizeContinuation),
                                gen: subdividedElement,
                            ),
                            continuation: { .pure($0) },
                        )

                        subrangeChoices.append(ReflectiveOperation.PickTuple(
                            siteID: context.makeID(),
                            id: context.makeID(),
                            weight: 1,
                            generator: subSeqGen,
                        ))
                    }

                    // Do NOT recurse into synthesized pick — inner generators are already subdivided
                    return .impure(
                        operation: .pick(choices: subrangeChoices),
                        continuation: continuation,
                    )
                }

                // Fallback: return sequence with subdivided element generator
                return .impure(
                    operation: .sequence(length: lengthGen, gen: subdividedElement),
                    continuation: continuation,
                )

            case let .pick(choices):
                var subdivided = ContiguousArray<ReflectiveOperation.PickTuple>()
                subdivided.reserveCapacity(choices.count)
                for choice in choices {
                    subdivided.append(ReflectiveOperation.PickTuple(
                        siteID: choice.siteID,
                        id: choice.id,
                        weight: choice.weight,
                        generator: try subdivideSequenceLengths(choice.generator, context: context),
                    ))
                }
                return .impure(operation: .pick(choices: subdivided), continuation: continuation)

            case let .zip(generators):
                let subdivided = try ContiguousArray(generators.map {
                    try subdivideSequenceLengths($0, context: context)
                })
                return .impure(operation: .zip(subdivided), continuation: continuation)

            case let .contramap(transform, next):
                return .impure(
                    operation: .contramap(
                        transform: transform,
                        next: try subdivideSequenceLengths(next, context: context),
                    ),
                    continuation: continuation,
                )

            case let .prune(next):
                return .impure(
                    operation: .prune(next: try subdivideSequenceLengths(next, context: context)),
                    continuation: continuation,
                )

            case let .resize(newSize, next):
                return .impure(
                    operation: .resize(
                        newSize: newSize,
                        next: try subdivideSequenceLengths(next, context: context),
                    ),
                    continuation: continuation,
                )

            case let .filter(subGen, fingerprint, filterType, predicate):
                return .impure(
                    operation: .filter(
                        gen: try subdivideSequenceLengths(subGen, context: context),
                        fingerprint: fingerprint,
                        filterType: filterType,
                        predicate: predicate,
                    ),
                    continuation: continuation,
                )

            case let .classify(subGen, fingerprint, classifiers):
                return .impure(
                    operation: .classify(
                        gen: try subdivideSequenceLengths(subGen, context: context),
                        fingerprint: fingerprint,
                        classifiers: classifiers,
                    ),
                    continuation: continuation,
                )

            case let .unique(subGen, fingerprint, keyExtractor):
                return .impure(
                    operation: .unique(
                        gen: try subdivideSequenceLengths(subGen, context: context),
                        fingerprint: fingerprint,
                        keyExtractor: keyExtractor,
                    ),
                    continuation: continuation,
                )

            case .chooseBits, .just, .getSize:
                return gen
            }
        }
    }
}
