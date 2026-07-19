//
//  ChoiceGradientTuner.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/2/2026.
//

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(WinSDK)
    import WinSDK
#endif

/// Three-stage offline tuner for pick-heavy generators (BST, AVL, and so on).
///
/// Pure online CGS (``OnlineCGSInterpreter``) gives excellent *ranking* of choices — it knows which picks lead to valid outputs — but it's expensive per-sample (derivative evaluation at every site) and overcommits to the dominant winner, quickly exhausting unique values. This tuner addresses both problems:
///
/// ## Stage 1: Online CGS warmup
///
/// Runs the generator through ``OnlineCGSInterpreter`` for a fixed number of warmup passes, collecting per-site, per-choice fitness data into a ``FitnessAccumulator``.
/// Unlike probe-based tuning which samples each site independently, CGS conditions on upstream choices via ``DerivativeContext``, producing better weights for recursive generators where the validity of a subtree depends on ancestors.
///
/// The warmup is the only expensive phase. All subsequent generation uses the cheap ``ValueAndChoiceTreeInterpreter`` with the baked weights — same quality signal, ~100x cheaper per sample.
///
/// ## Stage 2: Fitness-shared weight baking
///
/// Raw CGS fitness data assigns weights proportional to how often each choice led to valid outputs. If choice A succeeds 90% and choice B only 10%, the raw weights are 9:1. The generator then hammers choice A and quickly exhausts its unique values, while choice B — which leads to a different, equally valid region of the output space — is starved.
///
/// The default `.fitnessSharing` strategy redistributes weight via niche-count sharing: `weight_i = fitness_i / (1 + N × share_i)` where `share_i` is the choice's proportion of total fitness at the site. Dominant choices get a heavy divisor; minority choices get a light one. This preserves the ranking (choice A still outweighs choice B) while flattening the distribution toward the tail.
///
/// On AVL benchmarks, fitness sharing makes CGS-baked weights 2x faster than raw `totalFitness` baking and 3x faster than `Adaptive` for time-to-100 unique valid trees.
///
/// ## Stage 3: Adaptive smoothing
///
/// After baking, per-site entropy analysis identifies bottleneck sites — picks where one choice dominates — and applies higher temperature there to prevent any single site from becoming a chokepoint. Well-distributed sites keep low temperature to preserve the tuned distribution. This uses ``AdaptiveSmoothing/smooth(_:epsilon:baseTemperature:maxTemperature:)`` (also used by the probe-based tuner).
///
/// ## Result
///
/// A statically-tuned generator suitable for ``ValueAndChoiceTreeInterpreter``.
/// The three stages compose: CGS provides the right ranking, fitness sharing prevents overcommitment to the winner, and adaptive smoothing ensures no single site strangles diversity.
///
/// Online CGS warmup is based on the per-value derivative sampling algorithm (Goldstein, Ch. 3, Fig 3.3). The offline weight-baking pipeline draws on Tjoa et al., "Tuning Random Generators for Property-Based Testing" (OOPSLA2, 2025). Fitness sharing and adaptive smoothing are Exhaust extensions.
///
/// The tuner's ``FitnessAccumulator`` is the CGS-level instance of the output-space observation pattern. ``FilterObservation`` tracks the same kind of data (predicate satisfaction counts) at filter sites during generation. ``DirectedExploreRunner`` tracks it at the direction level during exploration. The accumulation pattern is shared; the dimension and consumer differ.
package enum ChoiceGradientTuner<FinalOutput> {
    /// How baked pick weights are derived from the accumulated fitness data.
    ///
    /// All strategies use the same CGS warmup data; they differ only in how that data is converted to static pick weights.
    public enum WeightingStrategy {
        /// Niche-count fitness sharing: weight = fitness / (1 + N × share).
        /// Discounts dominant choices proportionally — a choice with 90% of the fitness gets a heavy divisor while a 10% choice gets a light one.
        /// Preserves the CGS ranking while redistributing weight to the tail.
        /// Benchmarked as 2–3x faster than raw totalFitness or UCB alternatives on BST and AVL time-to-unique workloads.
        case fitnessSharing
    }

    /// Tunes a generator's pick weights using offline CGS warmup.
    ///
    /// - Parameters:
    ///   - generator: The generator to tune.
    ///   - predicate: Validity condition that generated values must satisfy.
    ///   - warmupRuns: Maximum number of warmup passes to collect fitness data. Defaults to 100. In practice, ψ-based convergence detection (5% weight-share stability threshold) stops warmup early — parameter sweeps across BST and recursive tree generators show that weights stabilize in fewer than 50 runs regardless of budget, so values above 100 are rarely reached. The default provides a 2x safety margin over observed convergence points.
    ///   - sampleCount: Number of derivative samples drawn per pick site per warmup run. Defaults to 10. Each sample evaluates a residual generator via ``CGSDerivativeInterpreter`` to measure fitness, so this parameter scales tuning cost linearly. Parameter sweeps show identical generation quality (validity rate, unique count, height distribution) for values 5 through 40 on pick-heavy generators (BSTs with depth 5, values 0...9 and 0...99). The default of 10 provides a 2x margin over the minimum effective value. Goldstein (Ch. 3, Table 3.1) used N=50 for BST/SORTED and N=400–500 for AVL/STLC in the original online CGS algorithm; the lower default here reflects that Exhaust's offline pipeline with SMC-style batched resampling and convergence detection extracts equivalent signal from fewer per-site samples.
    ///   - seed: Optional seed for deterministic tuning. If nil, uses a random seed.
    ///   - weightingStrategy: How accumulated fitness data is converted to static pick weights.
    ///   - subdivisionThresholds: Controls when `chooseBits` sites are subdivided into picks for CGS to guide.
    public static func tune(
        _ generator: Generator<FinalOutput>,
        predicate: @escaping (FinalOutput) -> Bool,
        warmupRuns: UInt64 = 100,
        sampleCount: UInt64 = 10,
        seed: UInt64? = nil,
        weightingStrategy: WeightingStrategy = .fitnessSharing,
        subdivisionThresholds: CGSSubdivisionThresholds = .default
    ) throws -> Generator<FinalOutput> {
        // Stage 0: Preprocess — subdivide chooseBits into picks over subranges so CGS can guide decisions (chooseBits sites are opaque to CGS). With default thresholds, only sequence lengths are subdivided. With relaxed thresholds, element generators inside sequences are also subdivided.
        let subdivisionContext = SubdivisionContext()
        let subdivided = try subdivideForCGS(generator, context: subdivisionContext, thresholds: subdivisionThresholds)

        // Stage 1: Online CGS warmup — the only expensive phase. Runs the subdivided generator through OnlineCGSInterpreter in batches, collecting per-site, per-choice fitness data conditioned on upstream choices. Values are discarded; only the accumulated fitness data matters.
        //
        // SMC-style interleaved resampling: after each batch (once past the minimum warmup), intermediate weights are baked from accumulated fitness and fed into the next batch's interpreter. Deep picks (depth >= 4), which fall back to static generator weights, benefit from progressively improved proposals rather than staying uniform.
        //
        // Convergence detection (early stopping): after each batch, check if per-site weight shares have stabilized. When the maximum absolute shift drops below 5%, further runs won't meaningfully change the baked weights — stop early to save warmup cost.
        let accumulator = FitnessAccumulator()
        let resamplingBatchSize: UInt64 = 20
        let minWarmupRuns: UInt64 = 40
        var completedRuns: UInt64 = 0
        var currentGen = subdivided
        let baseSeed = seed ?? Xoshiro256().seed

        while completedRuns < warmupRuns {
            let runsThisBatch = min(resamplingBatchSize, warmupRuns - completedRuns)
            let batchSeed = Xoshiro256.deriveSeed(from: baseSeed, at: completedRuns)

            var iterator = OnlineCGSInterpreter(
                currentGen,
                predicate: predicate,
                sampleCount: sampleCount,
                seed: batchSeed,
                maxRuns: runsThisBatch,
                fitnessAccumulator: accumulator,
                subdivisionThresholds: subdivisionThresholds
            )
            while try iterator.next() != nil {}

            completedRuns += runsThisBatch
            guard completedRuns < warmupRuns else { break }

            if completedRuns >= minWarmupRuns {
                if accumulator.hasConverged(threshold: 0.05) { break }
                currentGen = bakeWeights(subdivided, from: accumulator, strategy: weightingStrategy)
            }
        }

        // Stage 2: Weight baking — convert accumulated fitness into static pick weights using the chosen strategy. The default .fitnessSharing discounts dominant choices via niche-count sharing so the generator doesn't lock onto a narrow cluster.
        // With default thresholds, bake into the original generator to preserve structural compatibility with choice trees (needed for filter replay and reduction). With relaxed thresholds (#explore), bake into the subdivided generator so element-level subdivision picks carry their baked weights through to generation.
        let bakingTarget = subdivisionThresholds.minimumRangeSize < CGSSubdivisionThresholds.default.minimumRangeSize ? subdivided : generator
        let baked = bakeWeights(bakingTarget, from: accumulator, strategy: weightingStrategy)

        // Stage 3: Adaptive smoothing — per-site entropy analysis identifies bottleneck sites (where one choice dominates) and applies higher temperature there to prevent chokepoints, while leaving well-distributed sites alone to preserve the tuned distribution.
        let smoothed = AdaptiveSmoothing.smooth(baked, baseTemperature: 2.0, maxTemperature: 8.0)

        // Stage 4: Collapse uniform subdivision picks — if CGS found no signal for a subdivided chooseBits (all subrange weights are near-equal), replace the pick with the original chooseBits to avoid overhead. Restricted to picks Stage 0 created: a user-written oneOf of chooses matches the same structural shape, and collapsing it both breaks structural compatibility with the untuned generator (reduction and replay walk the declared pick) and widens gapped branch ranges into values from neither branch.
        return collapseUniformSubdivisions(smoothed, subdivisionFingerprints: subdivisionContext.issuedFingerprints)
    }

    /// Recursively walks the generator tree, replacing pick weights with accumulated fitness data from the online CGS tuning pass.
    private static func bakeWeights<Output>(
        _ gen: Generator<Output>,
        from accumulator: FitnessAccumulator,
        strategy: WeightingStrategy,
        depth: Int = 0
    ) -> Generator<Output> {
        switch gen {
            case .pure:
                return gen

            case let .impure(operation, continuation):
                switch operation {
                    case let .pick(choices, _):
                        var baked = ContiguousArray<ReflectiveOperation.PickTuple>()
                        baked.reserveCapacity(choices.count)
                        let depthOffset = UInt64(depth) &* 0x9E37_79B9_7F4A_7C15

                        let precomputedWeights = computeFitnessSharingWeights(
                            choices: choices, records: accumulator.records, fingerprintOffset: depthOffset
                        )

                        for (index, choice) in choices.enumerated() {
                            let weight = precomputedWeights[index]
                            baked.append(ReflectiveOperation.PickTuple(
                                fingerprint: choice.fingerprint,
                                id: choice.id,
                                weight: Swift.max(1, weight),
                                generator: bakeWeights(
                                    choice.generator,
                                    from: accumulator,
                                    strategy: strategy,
                                    depth: depth + 1
                                )
                            ))
                        }
                        return .impure(operation: .pick(choices: baked, totalWeight: baked.reduce(0) { $0 &+ $1.weight }), continuation: continuation)

                    case let .zip(generators, _):
                        let bakedGens = ContiguousArray(generators.map {
                            bakeWeights($0, from: accumulator, strategy: strategy, depth: depth + 1)
                        })
                        return .impure(operation: .zip(bakedGens), continuation: continuation)

                    case let .sequence(lengthGen, elementGen):
                        // The interpreter pushes one `.sequenceElement` derivative frame per element, so picks inside the element generator accumulate one depth deeper — bake the element at `depth + 1` to land on the same key. The length generator runs in a fresh context maxed at `maxDerivativeDepth`, so its picks hit handlePick's fast path and never record; its bake depth is immaterial, so leave it at `depth`.
                        return .impure(
                            operation: .sequence(
                                length: bakeWeights(lengthGen, from: accumulator, strategy: strategy, depth: depth),
                                gen: bakeWeights(elementGen, from: accumulator, strategy: strategy, depth: depth + 1)
                            ),
                            continuation: continuation
                        )

                    default:
                        // A reified `bind` (`transform(.bind)`) pushes a `.bind` derivative frame during accumulation; mirror that by baking its inner one depth deeper. A forward-only `map` pushes no frame and stays at `depth`.
                        let innerDepth = operation.pushesBindFrameOnInnerDescent ? depth + 1 : depth
                        if let mapped = operation.mapInnerGenerator({ bakeWeights($0, from: accumulator, strategy: strategy, depth: innerDepth) }) {
                            return .impure(operation: mapped, continuation: continuation)
                        }
                        return gen
                }
        }
    }

    // MARK: - Fitness Sharing

    /// Niche-count fitness sharing: prevents the generator from overcommitting to the dominant choice at each pick site.
    ///
    /// For each choice, `share_i = fitness_i / siteTotal` measures how much of the site's total fitness it accounts for. The niche count `1 + N × share_i` grows with dominance: a choice with 90% share among 4 choices gets divisor 1 + 4×0.9 = 4.6, while a 10% choice gets 1 + 4×0.1 = 1.4. Dividing raw fitness by the niche count compresses the ratio from 9:1 down to ~1.96:0.71 ≈ 2.7:1 — still favoring the winner, but giving the minority choice meaningful sampling probability.
    private static func computeFitnessSharingWeights(
        choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        records: [FitnessAccumulator.SiteChoiceKey: FitnessAccumulator.FitnessRecord],
        fingerprintOffset: UInt64 = 0
    ) -> ContiguousArray<UInt64> {
        let count = choices.count
        var rawFitnesses = ContiguousArray<Double>()
        rawFitnesses.reserveCapacity(count)

        // Pass 1: gather raw fitnesses and site total
        var siteTotal: Double = 0
        for choice in choices {
            let key = FitnessAccumulator.SiteChoiceKey(fingerprint: choice.fingerprint &+ fingerprintOffset, choiceID: choice.id)
            let fitness = records[key].map { Double($0.totalFitness) } ?? 0
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

    // MARK: - Sequence Length Subdivision

    private final class SubdivisionContext {
        var nextID: UInt64 = .max / 2
        let maxSize: UInt64
        /// Every fingerprint issued to a subdivision pick's choices, so post-tuning passes can tell tuner-created picks from user-written ones. The counter band alone cannot: user pick fingerprints are source-fingerprint hashes, uniform over UInt64, so about half of them would land in any reserved band.
        private(set) var issuedFingerprints: Set<UInt64> = []
        init(maxSize: UInt64 = 100) {
            self.maxSize = maxSize
        }

        func makeID() -> UInt64 {
            defer { nextID &+= 1 }
            issuedFingerprints.insert(nextID)
            return nextID
        }
    }

    /// Preprocessing pass that rewrites sequence operations by converting their length generators into picks over subranges. This makes the length decision CGS-guidable at O(S × 4 × N_avg) cost instead of the O(N² × S) cost of per-element derivative composition.
    private static func subdivideForCGS<Output>(
        _ gen: Generator<Output>,
        context: SubdivisionContext,
        thresholds: CGSSubdivisionThresholds
    ) throws -> Generator<Output> {
        switch gen {
            case .pure:
                return gen

            case let .impure(operation, continuation):
                switch operation {
                    case let .sequence(lengthGen, elementGen):
                        // 1. Recurse into element generator, then subdivide its chooseBits if thresholds allow
                        var subdividedElement = try subdivideForCGS(elementGen, context: context, thresholds: thresholds)
                        subdividedElement = try subdivideChooseBits(subdividedElement, context: context, thresholds: thresholds)

                        // 2a. Check if length generator is a direct .chooseBits with range > 4
                        if case let .impure(
                            .chooseBits(lower, upper, tag, isRangeExplicit, scaling, _),
                            lengthContinuation
                        ) = lengthGen {
                            let rangeSize = (lower ... upper).saturatingCount
                            if rangeSize > 4 {
                                let subrangeCount = Swift.min(4, Int(Swift.min(rangeSize, UInt64(Int.max))))
                                let subranges = (lower ... upper).split(into: subrangeCount)

                                var subrangeChoices = ContiguousArray<ReflectiveOperation.PickTuple>()
                                subrangeChoices.reserveCapacity(subranges.count)

                                for (index, subrange) in subranges.enumerated() {
                                    let subLengthGen: Generator<UInt64> = .impure(
                                        operation: .chooseBits(
                                            min: subrange.lowerBound,
                                            max: subrange.upperBound,
                                            tag: tag,
                                            isRangeExplicit: isRangeExplicit,
                                            scaling: scaling
                                        ),
                                        continuation: lengthContinuation
                                    )

                                    let subSeqGen: AnyGenerator = .impure(
                                        operation: .sequence(length: subLengthGen, gen: subdividedElement),
                                        continuation: { .pure($0) }
                                    )

                                    subrangeChoices.append(ReflectiveOperation.PickTuple(
                                        fingerprint: context.makeID(),
                                        id: UInt64(index),
                                        weight: 1,
                                        generator: subSeqGen
                                    ))
                                }

                                // Do NOT recurse into synthesized pick — inner generators are already subdivided
                                return .impure(
                                    operation: .pick(choices: subrangeChoices, totalWeight: subrangeChoices.reduce(0) { $0 &+ $1.weight }),
                                    continuation: continuation
                                )
                            }
                        }

                        // 2b. Check if length generator is .getSize → continuation
                        if let getSizeContinuation = lengthGen.getSizeContinuation {
                            let subranges = (0 ... context.maxSize).split(
                                into: Swift.min(4, Int(context.maxSize + 1))
                            )

                            var subrangeChoices = ContiguousArray<ReflectiveOperation.PickTuple>()
                            subrangeChoices.reserveCapacity(subranges.count)

                            for (index, subrange) in subranges.enumerated() {
                                let subSizeGen: Generator<UInt64> = .impure(
                                    operation: .chooseBits(
                                        min: subrange.lowerBound,
                                        max: subrange.upperBound,
                                        tag: .uint64,
                                        isRangeExplicit: false
                                    ),
                                    continuation: { .pure($0 as! UInt64) }
                                )

                                // swiftlint:disable:next force_cast
                                let subLengthGen = try subSizeGen.bindReified(getSizeContinuation).map { $0 as! UInt64 }
                                let subSeqGen: AnyGenerator = .impure(
                                    operation: .sequence(
                                        length: subLengthGen,
                                        gen: subdividedElement
                                    ),
                                    continuation: { .pure($0) }
                                )

                                subrangeChoices.append(ReflectiveOperation.PickTuple(
                                    fingerprint: context.makeID(),
                                    id: UInt64(index),
                                    weight: 1,
                                    generator: subSeqGen
                                ))
                            }

                            // Do NOT recurse into synthesized pick — inner generators are already subdivided
                            return .impure(
                                operation: .pick(choices: subrangeChoices, totalWeight: subrangeChoices.reduce(0) { $0 &+ $1.weight }),
                                continuation: continuation
                            )
                        }

                        // Fallback: return sequence with subdivided element generator
                        return .impure(
                            operation: .sequence(length: lengthGen, gen: subdividedElement),
                            continuation: continuation
                        )

                    case let .pick(choices, _):
                        var subdivided = ContiguousArray<ReflectiveOperation.PickTuple>()
                        subdivided.reserveCapacity(choices.count)
                        for choice in choices {
                            try subdivided.append(ReflectiveOperation.PickTuple(
                                fingerprint: choice.fingerprint,
                                id: choice.id,
                                weight: choice.weight,
                                generator: subdivideForCGS(choice.generator, context: context, thresholds: thresholds)
                            ))
                        }
                        return .impure(operation: .pick(choices: subdivided, totalWeight: subdivided.reduce(0) { $0 &+ $1.weight }), continuation: continuation)

                    case let .zip(generators, _):
                        let subdivided = try ContiguousArray(generators.map {
                            try subdivideForCGS($0, context: context, thresholds: thresholds)
                        })
                        return .impure(operation: .zip(subdivided), continuation: continuation)

                    default:
                        if let mapped = try operation.mapInnerGenerator({ try subdivideForCGS($0, context: context, thresholds: thresholds) }) {
                            return .impure(operation: mapped, continuation: continuation)
                        }
                        return gen
                }
        }
    }

    /// Collapses subdivision picks where CGS found no signal (all subrange weights are near-equal) back to a single `chooseBits`. Only picks whose choice fingerprints were issued by the ``SubdivisionContext`` are candidates — user-written picks keep their declared structure.
    private static func collapseUniformSubdivisions<Output>(
        _ gen: Generator<Output>,
        subdivisionFingerprints: Set<UInt64>
    ) -> Generator<Output> {
        switch gen {
            case .pure:
                return gen

            case let .impure(operation, continuation):
                switch operation {
                    case let .pick(choices, _) where choices.count >= 2:
                        if choices.allSatisfy({ subdivisionFingerprints.contains($0.fingerprint) }),
                           let collapsed: Generator<Output> = collapseIfUniform(choices, continuation: continuation)
                        {
                            return collapsed
                        }
                        let recursed = ContiguousArray(choices.map { choice in
                            ReflectiveOperation.PickTuple(
                                fingerprint: choice.fingerprint,
                                id: choice.id,
                                weight: choice.weight,
                                generator: collapseUniformSubdivisions(choice.generator, subdivisionFingerprints: subdivisionFingerprints)
                            )
                        })
                        return .impure(operation: .pick(choices: recursed, totalWeight: recursed.reduce(0) { $0 &+ $1.weight }), continuation: continuation)

                    case let .sequence(lengthGen, elementGen):
                        return .impure(
                            operation: .sequence(
                                length: collapseUniformSubdivisions(lengthGen, subdivisionFingerprints: subdivisionFingerprints),
                                gen: collapseUniformSubdivisions(elementGen, subdivisionFingerprints: subdivisionFingerprints)
                            ),
                            continuation: continuation
                        )

                    case let .zip(generators, _):
                        let recursed = ContiguousArray(generators.map { collapseUniformSubdivisions($0, subdivisionFingerprints: subdivisionFingerprints) })
                        return .impure(operation: .zip(recursed), continuation: continuation)

                    default:
                        if let mapped = operation.mapInnerGenerator({ collapseUniformSubdivisions($0, subdivisionFingerprints: subdivisionFingerprints) }) {
                            return .impure(operation: mapped, continuation: continuation)
                        }
                        return gen
                }
        }
    }

    /// Returns a collapsed `chooseBits` if all choices in the pick are `chooseBits` subranges with near-equal weights. Returns `nil` if the pick has signal and should be kept.
    private static func collapseIfUniform<Output>(
        _ choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        continuation: @escaping (Any) throws -> AnyGenerator
    ) -> Generator<Output>? {
        let maxWeight = choices.max(by: { $0.weight < $1.weight })!.weight
        let minWeight = choices.min(by: { $0.weight < $1.weight })!.weight
        guard minWeight > 0 else { return nil }
        let ratio = Double(maxWeight) / Double(minWeight)
        guard ratio < 1.5 else { return nil }

        var globalMin: UInt64 = .max
        var globalMax: UInt64 = .min
        var tag: TypeTag?
        var isRangeExplicit: Bool?
        var scaling: ChooseBitsScaling?
        var innerContinuation: ((Any) throws -> AnyGenerator)?

        for choice in choices {
            guard case let .impure(.chooseBits(lower, upper, choiceTag, choiceExplicit, choiceScaling, _), choiceContinuation) = choice.generator else {
                return nil
            }
            globalMin = Swift.min(globalMin, lower)
            globalMax = Swift.max(globalMax, upper)
            if innerContinuation == nil {
                innerContinuation = choiceContinuation
            }
            if let existingTag = tag {
                guard existingTag == choiceTag else { return nil }
            } else {
                tag = choiceTag
                isRangeExplicit = choiceExplicit
                scaling = choiceScaling
            }
        }

        guard let tag, let isRangeExplicit, let innerContinuation else { return nil }

        return .impure(
            operation: .chooseBits(
                min: globalMin,
                max: globalMax,
                tag: tag,
                isRangeExplicit: isRangeExplicit,
                scaling: scaling
            ),
            continuation: { value in
                let inner = try innerContinuation(value)
                guard case let .pure(innerValue) = inner else {
                    return try continuation(value)
                }
                return try continuation(innerValue)
            }
        )
    }

    /// Subdivides a top-level `chooseBits` into a pick over subranges if the range meets the threshold. Leaves non-chooseBits generators unchanged.
    private static func subdivideChooseBits<Output>(
        _ gen: Generator<Output>,
        context: SubdivisionContext,
        thresholds: CGSSubdivisionThresholds
    ) throws -> Generator<Output> {
        guard case let .impure(.chooseBits(lower, upper, tag, isRangeExplicit, scaling, _), chooseContinuation) = gen else {
            return gen
        }
        let rangeSize = (lower ... upper).saturatingCount
        guard rangeSize >= thresholds.minimumRangeSize else {
            return gen
        }
        guard let choices = SharedInterpreterHelpers.subdivideChooseBits(
            lower: lower, upper: upper, tag: tag,
            isRangeExplicit: isRangeExplicit, scaling: scaling,
            makeFingerprint: { context.makeID() },
            innerContinuation: { try chooseContinuation($0).erase() }
        ) else {
            return gen
        }

        return .impure(
            operation: .pick(choices: choices, totalWeight: choices.reduce(0) { $0 &+ $1.weight }),
            continuation: { .pure($0 as! Output) } // swiftlint:disable:this force_cast
        )
    }
}

private extension ReflectiveOperation {
    /// True when ``OnlineCGSInterpreter`` pushes a derivative frame while descending into this operation's inner generator, so `bakeWeights` must descend one depth deeper to land on the same `(fingerprint, depth)` accumulation key. A reified `bind` pushes a `.bind` frame; a forward-only `map` pushes nothing.
    var pushesBindFrameOnInnerDescent: Bool {
        if case let .transform(kind, _) = self, case .bind = kind {
            return true
        }
        return false
    }
}
