//
//  GeneratorTuning.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/2/2026.
//

import Foundation

/// Offline, one-shot tuning that transforms a generator's pick structure using fitness-weighted sampling inspired by Choice Gradient Sampling (CGS).
///
/// Tuning is performed once at creation time via a single top-down recursive pass. The result is a normal `ReflectiveGenerator` with synthesised pick structure whose weights reflect predicate satisfaction rates. Shrinking is unaffected because the reducer operates on `ChoiceTree`/`ChoiceSequence` and is weight-agnostic.
///
/// ## Algorithm
///
/// At every `pick`, each choice is sampled through the continuation pipeline to measure how often the final output satisfies the predicate. The measured success count becomes the choice's weight. Inner generators are recursively tuned using *composed predicates* — the current continuation is folded into the predicate so that inner operations always evaluate against the final output.
///
/// `chooseBits` and `getSize` operations are subdivided into synthesised picks of subranges, then tuned through the pick path.
///
/// The specification-entropy objective and symbolic weight computation are based on Tjoa et al., "Tuning Random Generators for Property-Based Testing" (OOPSLA2, 2025). Exhaust diverges by using convergence-gated batched sampling instead of the paper's fixed sample budget.
public enum GeneratorTuning {
    // MARK: - Context

    final class TuningContext {
        let baseSampleCount: UInt64
        let maxSize: UInt64
        var depth: UInt64 = 0
        var rng: Xoshiro256

        init(baseSampleCount: UInt64, maxSize: UInt64, rng: consuming Xoshiro256) {
            self.baseSampleCount = baseSampleCount
            self.maxSize = maxSize
            self.rng = rng
        }

        /// Sample budget decays linearly with depth as a safety ceiling.
        /// Convergence detection in `measureAndTunePick` typically stops well before this cap, so deeper sites still get meaningful signal.
        var maxSamplesPerSite: UInt64 {
            max(1, baseSampleCount / (1 + depth))
        }
    }

    // MARK: - Convergence Constants

    /// Number of samples per choice in each batch before checking convergence.
    private static let convergenceBatchSize: UInt64 = 20

    /// Maximum absolute shift in normalized weights to consider converged.
    private static let convergenceThreshold: Double = 0.05

    /// Minimum total samples per choice before convergence checks begin (2 × batchSize).
    private static let convergenceMinSamples: UInt64 = 40

    /// Minimum selection probability per choice. Prevents extreme weight ratios from compounding across depth levels, which would collapse rare-but-valid deep paths to near-zero probability. The paper (§4.3, Figure 13) shows that bounding weights to [0.1, 0.9] prevents overfitting and improves output diversity.
    ///
    /// **Caveat for wide picks:** the floor applies per-choice, so a pick with many dead branches pays a cost proportional to `deadBranches / totalBranches`.
    /// Binary picks lose at most ~10% of selection probability to the floor, but e.g. a 20-way pick with 2 valid branches drops valid selection from ~100% to ~36%. If this becomes a problem, scale the fraction inversely with branch count (`weightFloorFraction / choiceCount`) to cap total floor budget at a fixed share of weight regardless of branch count.
    private static let weightFloorFraction: Double = 0.1

    // MARK: - Public API

    /// Probes a generator's structure by running it a few times and checking whether the resulting choice trees contain any pick sites. If picks are present, performs full tuning with adaptive smoothing. If not, returns the generator unchanged — tuning has nothing to attach weights to.
    ///
    /// - Parameters:
    ///   - generator: The generator to probe and possibly tune.
    ///   - probeSeed: Seed for the probe runs (default 0).
    ///   - probeRuns: Number of probe generations to inspect (default 10).
    ///   - minPerChoice: Minimum samples per choice at the deepest pick level (default 30).
    ///   - maxSamples: Upper bound on the computed sample count (default 5000).
    ///   - maxRuns: Planned generation volume. When provided, the tuning budget is capped so that tuning doesn't dwarf generation time for small runs.
    ///   - maxSize: Maximum size parameter used when subdividing `getSize`.
    ///   - seed: Optional seed for deterministic tuning.
    ///   - predicate: The property that generated values should satisfy.
    /// - Returns: A tuned generator if picks were found, or the original generator unchanged.
    public static func probeAndTune<Output>(
        _ generator: ReflectiveGenerator<Output>,
        probeSeed: UInt64 = 0,
        probeRuns: UInt64 = 10,
        minPerChoice: UInt64 = 30,
        maxSamples: UInt64 = 5000,
        maxRuns: UInt64? = nil,
        maxSize: UInt64 = 100,
        seed: UInt64? = nil,
        predicate: @escaping (Output) -> Bool
    ) throws -> ReflectiveGenerator<Output> {
        var probe = ValueAndChoiceTreeInterpreter(generator, seed: probeSeed, maxRuns: probeRuns)
        var maxComplexity: UInt64 = 0

        while let (_, tree) = try probe.next() {
            maxComplexity = max(maxComplexity, tree.pickComplexity)
        }

        guard maxComplexity > 0 else { return generator }

        var samples = min(maxSamples, minPerChoice * maxComplexity)

        // Cap tuning budget relative to planned generation volume.
        // Tuning cost should not dwarf generation time — for small runs
        // we only need directionally correct weights, not precise ones.
        // Convergence detection handles the rest.
        if let maxRuns {
            samples = min(samples, max(convergenceMinSamples, maxRuns / 5))
        }

        let tuned = try tune(
            generator,
            samples: samples,
            maxSize: maxSize,
            seed: seed,
            predicate: predicate
        )
        return smoothAdaptively(tuned)
    }

    /// Tunes a generator so that its pick weights reflect predicate satisfaction rates.
    ///
    /// The transformation is eager — the returned generator has its structure fully tuned and can be used with any interpreter.
    ///
    /// - Parameters:
    ///   - generator: The generator to tune.
    ///   - samples: Base number of samples per pick choice (decays with depth).
    ///   - maxSize: Maximum size parameter used when subdividing `getSize`.
    ///   - seed: Optional seed for deterministic tuning.
    ///   - predicate: The property that generated values should satisfy.
    /// - Returns: A tuned generator with weights biased toward predicate satisfaction.
    public static func tune<Output>(
        _ generator: ReflectiveGenerator<Output>,
        samples: UInt64 = 100,
        maxSize: UInt64 = 100,
        seed: UInt64? = nil,
        predicate: @escaping (Output) -> Bool
    ) throws -> ReflectiveGenerator<Output> {
        let rng = if let seed {
            Xoshiro256(seed: seed)
        } else {
            Xoshiro256()
        }
        let context = TuningContext(
            baseSampleCount: samples,
            maxSize: maxSize,
            rng: rng
        )
        return try tuneRecursive(
            generator,
            context: context,
            insideSubdividedChooseBits: false,
            predicate: predicate
        )
    }

    // MARK: - Recursive Engine

    private static func tuneRecursive<Output>(
        _ gen: ReflectiveGenerator<Output>,
        context: TuningContext,
        insideSubdividedChooseBits: Bool,
        predicate: @escaping (Output) -> Bool
    ) throws -> ReflectiveGenerator<Output> {
        switch gen {
        case .pure:
            return gen

        case let .impure(op, continuation):
            switch op {
            case let .pick(choices):
                return try measureAndTunePick(
                    choices: choices,
                    continuation: continuation,
                    context: context,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    predicate: predicate
                )

            case let .chooseBits(lower, upper, tag, isRangeExplicit):
                if insideSubdividedChooseBits {
                    return gen
                }
                return try tuneChooseBits(
                    lower: lower,
                    upper: upper,
                    tag: tag,
                    isRangeExplicit: isRangeExplicit,
                    continuation: continuation,
                    context: context,
                    predicate: predicate
                )

            case let .sequence(lengthGen, elementGen):
                return try tuneSequence(
                    lengthGen: lengthGen,
                    elementGen: elementGen,
                    continuation: continuation,
                    context: context,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    predicate: predicate
                )

            case .getSize:
                return try tuneGetSize(
                    continuation: continuation,
                    context: context,
                    predicate: predicate
                )

            case let .zip(generators, _):
                return try tuneZip(
                    generators: generators,
                    continuation: continuation,
                    context: context,
                    predicate: predicate
                )

            case let .filter(subGen, fingerprint, filterType, filterPredicate):
                return try tuneFilter(
                    subGen: subGen,
                    fingerprint: fingerprint,
                    filterType: filterType,
                    filterPredicate: filterPredicate,
                    continuation: continuation,
                    context: context
                )

            case let .contramap(transform, next):
                return try tuneContramap(
                    transform: transform,
                    next: next,
                    continuation: continuation,
                    context: context,
                    predicate: predicate
                )

            case let .resize(newSize, next):
                return try tuneResize(
                    newSize: newSize,
                    next: next,
                    continuation: continuation,
                    context: context,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    predicate: predicate
                )

            case let .unique(subGen, fingerprint, keyExtractor):
                let tunedInner = try tuneRecursive(
                    subGen,
                    context: context,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    predicate: { _ in true }
                )
                return .impure(
                    operation: .unique(
                        gen: tunedInner,
                        fingerprint: fingerprint,
                        keyExtractor: keyExtractor
                    ),
                    continuation: continuation
                )

            case let .transform(kind, inner):
                let tunedInner = try tuneRecursive(
                    inner,
                    context: context,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    predicate: { _ in true }
                )
                return .impure(
                    operation: .transform(kind: kind, inner: tunedInner),
                    continuation: continuation
                )

            case .just, .prune, .classify:
                return gen
            }
        }
    }

    // MARK: - Pick

    private static func measureAndTunePick<Output>(
        choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        context: TuningContext,
        insideSubdividedChooseBits: Bool,
        predicate: @escaping (Output) -> Bool
    ) throws -> ReflectiveGenerator<Output> {
        context.depth += 1
        defer { context.depth -= 1 }

        let choiceCount = choices.count
        let maxSamples = context.maxSamplesPerSite

        // --- Phase 1: Batched sampling of all choices with convergence ---

        // Per-choice state: independent RNG stream (stored as seed+state tuples
        // since ~Copyable Xoshiro256 can't be stored in Array), accumulators, cache
        var choiceRngStates: [(seed: UInt64, state: Xoshiro256.StateType)] =
            (0 ..< choiceCount).map {
            let rng = context.rng.spawned(streamID: UInt64($0))
            return (rng.seed, rng.currentState)
        }
        var successCounts = Array(repeating: UInt64(0), count: choiceCount)
        var outputFrequencies = Array(repeating: [AnyHashable: UInt64](), count: choiceCount)
        var continuationCaches = Array(repeating: [AnyHashable: Bool](), count: choiceCount)
        var totalSampled: UInt64 = 0

        // Previous normalized weights for convergence comparison
        var previousNormalized = Array(repeating: 0.0, count: choiceCount)

        // Trivial single-choice picks converge immediately after minimum samples
        let isTrivial = choiceCount <= 1

        // Scale minimum samples with depth — deep sites shouldn't be forced
        // to the full 40-sample floor when their cap is already low.
        let effectiveMinSamples = min(convergenceMinSamples, maxSamples)

        while totalSampled < maxSamples {
            let batchEnd = min(totalSampled + convergenceBatchSize, maxSamples)

            // Sample one batch for every choice
            for choiceIdx in 0 ..< choiceCount {
                var rng = Xoshiro256(
                    seed: choiceRngStates[choiceIdx].seed,
                    state: choiceRngStates[choiceIdx].state
                )
                for _ in totalSampled ..< batchEnd {
                    // Advance RNG to ensure each sample sees a unique state.
                    // Without this, choices with trivial generators (e.g. .just)
                    // leave the RNG frozen — the entire predicate chain may
                    // consist of .pure unwrapping that consumes no randomness,
                    // making all samples identical.
                    _ = rng.next()

                    guard let innerValue = try ValueInterpreter<Any>.generate(
                        choices[choiceIdx].generator, maxRuns: 1, using: &rng
                    ) else { continue }

                    let success: Bool
                    var output: Output?
                    do {
                        let nextGen = try continuation(innerValue)
                        output = try ValueInterpreter<Output>.generate(
                            nextGen, maxRuns: 1, using: &rng
                        )
                        success = output.map(predicate) ?? false
                    } catch {
                        success = false
                    }

                    if success {
                        successCounts[choiceIdx] += 1
                        if let hashable = output as? AnyHashable {
                            outputFrequencies[choiceIdx][hashable, default: 0] += 1
                        }
                    }
                    if let hashable = innerValue as? AnyHashable {
                        continuationCaches[choiceIdx][hashable] = success
                    }
                }
                choiceRngStates[choiceIdx] = (rng.seed, rng.currentState)
            }

            totalSampled = batchEnd

            // Trivial picks (single choice) are converged by definition
            if isTrivial, totalSampled >= effectiveMinSamples { break }

            // All checks below require the minimum sample floor
            guard totalSampled >= effectiveMinSamples else { continue }

            // Unambiguous early exit: if one choice has ≥80% success rate and
            // another has 0%, the signal is clear — stop without waiting for
            // the second convergence check (which needs one more batch to see
            // the shift stabilize).
            if !isTrivial {
                let hasZero = successCounts.contains(0)
                let maxRate = Double(successCounts.max()!) / Double(totalSampled)
                if hasZero, maxRate >= 0.8 {
                    break
                }
            }

            // All-zero successes: skip convergence, keep sampling to the cap
            let totalSuccesses = successCounts.reduce(0, +)
            guard totalSuccesses > 0 else { continue }

            // Compute normalized success distribution
            let normalized = successCounts.map {
                Double($0) / Double(totalSuccesses)
            }

            // Check max absolute shift from previous normalized distribution
            let maxShift = zip(normalized, previousNormalized)
                .map { abs($0 - $1) }
                .max() ?? .infinity

            if maxShift < convergenceThreshold {
                break
            }

            previousNormalized = normalized
        }

        // Advance context RNG once for deterministic Phase 2
        context.rng.jump()

        // --- Phase 2: Recursive tuning per choice ---

        var tunedChoices = ContiguousArray<ReflectiveOperation.PickTuple>()
        tunedChoices.reserveCapacity(choiceCount)

        // Only skip dominated branches if at least one branch has positive
        // successes. When all branches scored 0, the all-zero fallback will
        // restore weight 1, so those branches need tuned inner generators.
        let hasAnySuccess = successCounts.contains(where: { $0 > 0 })

        for choiceIdx in 0 ..< choiceCount {
            let choice = choices[choiceIdx]

            // Skip recursive tuning for dominated branches — their weight
            // will be 0 and they won't be selected during generation.
            if hasAnySuccess, successCounts[choiceIdx] == 0 {
                tunedChoices.append(ReflectiveOperation.PickTuple(
                    siteID: choice.siteID,
                    id: choice.id,
                    weight: 0,
                    generator: choice.generator
                ))
                continue
            }

            // The composed predicate checks the cache from Phase 1 first,
            // falling back to full continuation evaluation on cache miss.
            var composedRng = Xoshiro256(
                seed: choiceRngStates[choiceIdx].seed,
                state: choiceRngStates[choiceIdx].state
            )
            let cache = continuationCaches[choiceIdx]
            let composedPredicate: (Any) -> Bool = { innerValue in
                if let hashable = innerValue as? AnyHashable,
                   let cached = cache[hashable]
                {
                    return cached
                }
                do {
                    let nextGen = try continuation(innerValue)
                    let output = try ValueInterpreter<Output>.generate(
                        nextGen,
                        maxRuns: 1,
                        using: &composedRng
                    )
                    return output.map(predicate) ?? false
                } catch {
                    return false
                }
            }

            let tunedInner = try tuneRecursive(
                choice.generator,
                context: context,
                insideSubdividedChooseBits: insideSubdividedChooseBits,
                predicate: composedPredicate
            )

            // Specification entropy weighting: reward branches that produce
            // diverse valid outputs, not just frequent ones.  We estimate
            // Shannon entropy from the empirical frequency distribution of
            // valid outputs.  This is strictly more informative than the
            // previous distinct-count heuristic: two branches may each produce
            // 10 distinct outputs, but if one concentrates 90% of mass on a
            // single value the entropy will be low, correctly down-weighting it.
            // The +1 offset ensures branches with a single valid output still
            // receive weight proportional to their success count.
            let frequencies = outputFrequencies[choiceIdx]
            let totalObservations = frequencies.values.reduce(UInt64(0), +)
            let entropy: Double
            if totalObservations <= 1 {
                entropy = 0
            } else {
                let total = Double(totalObservations)
                entropy = -frequencies.values.reduce(0.0) { acc, count in
                    let p = Double(count) / total
                    return acc + p * log(p)
                }
            }
            let weight = UInt64(Double(successCounts[choiceIdx]) * (1 + entropy))

            tunedChoices.append(ReflectiveOperation.PickTuple(
                siteID: choice.siteID,
                id: choice.id,
                weight: weight,
                generator: tunedInner
            ))
        }

        // Weight floor: bound each choice's selection probability to at least
        // weightFloorFraction. This prevents extreme ratios from compounding
        // multiplicatively across depth (e.g. 0.9^5 leaf bias at every level
        // would collapse h5 BST probability to 0.00001%).
        let totalWeight = tunedChoices.reduce(UInt64(0)) { $0 + $1.weight }
        if totalWeight > 0 {
            let floor = max(UInt64(1), UInt64(Double(totalWeight) * weightFloorFraction))
            tunedChoices = ContiguousArray(tunedChoices.map { choice in
                guard choice.weight < floor else { return choice }
                return ReflectiveOperation.PickTuple(
                    siteID: choice.siteID, id: choice.id,
                    weight: floor, generator: choice.generator
                )
            })
        }

        // All-zero safety: restore with weight 1 to prevent draw returning nil
        if tunedChoices.allSatisfy({ $0.weight == 0 }) {
            tunedChoices = ContiguousArray(tunedChoices.map {
                ReflectiveOperation.PickTuple(
                    siteID: $0.siteID,
                    id: $0.id,
                    weight: 1,
                    generator: $0.generator
                )
            })
        }

        return .impure(
            operation: .pick(choices: tunedChoices),
            continuation: continuation
        )
    }

    // MARK: - ChooseBits

    private static func tuneChooseBits<Output>(
        lower: UInt64,
        upper: UInt64,
        tag: TypeTag,
        isRangeExplicit: Bool,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        context: TuningContext,
        predicate: @escaping (Output) -> Bool
    ) throws -> ReflectiveGenerator<Output> {
        context.depth += 1
        defer { context.depth -= 1 }

        let rangeSize = upper - lower + 1
        let subrangeCount = min(4, Int(min(rangeSize, UInt64(Int.max))))
        let subranges = (lower ... upper).split(into: subrangeCount)

        var subrangeChoices = ContiguousArray<ReflectiveOperation.PickTuple>()
        subrangeChoices.reserveCapacity(subranges.count)

        for subrange in subranges {
            let subGen: ReflectiveGenerator<Any> = .impure(
                operation: .chooseBits(
                    min: subrange.lowerBound,
                    max: subrange.upperBound,
                    tag: tag,
                    isRangeExplicit: isRangeExplicit
                ),
                continuation: { .pure($0) }
            )
            subrangeChoices.append(ReflectiveOperation.PickTuple(
                siteID: context.rng.next(),
                id: context.rng.next(),
                weight: 1,
                generator: subGen
            ))
        }

        let synthesisedPick: ReflectiveGenerator<Output> = .impure(
            operation: .pick(choices: subrangeChoices),
            continuation: continuation
        )

        // Re-enter tuneRecursive to weight the synthesised pick
        return try tuneRecursive(
            synthesisedPick,
            context: context,
            insideSubdividedChooseBits: true,
            predicate: predicate
        )
    }

    // MARK: - Sequence

    private static func tuneSequence<Output>(
        lengthGen: ReflectiveGenerator<UInt64>,
        elementGen: ReflectiveGenerator<Any>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        context: TuningContext,
        insideSubdividedChooseBits: Bool,
        predicate: @escaping (Output) -> Bool
    ) throws -> ReflectiveGenerator<Output> {
        // Try to subdivide the length generator if it's a chooseBits
        // (only if we haven't already subdivided)
        if !insideSubdividedChooseBits,
           case let .impure(
            .chooseBits(lower, upper, tag, isRangeExplicit),
            lengthContinuation
           ) = lengthGen
        {
            context.depth += 1
            defer { context.depth -= 1 }

            let rangeSize = upper - lower + 1
            let subrangeCount = min(4, Int(min(rangeSize, UInt64(Int.max))))
            let subranges = (lower ... upper).split(into: subrangeCount)

            var subrangeChoices = ContiguousArray<ReflectiveOperation.PickTuple>()
            subrangeChoices.reserveCapacity(subranges.count)

            for subrange in subranges {
                // Create a sub-length generator for this subrange
                let subLengthGen: ReflectiveGenerator<UInt64> = .impure(
                    operation: .chooseBits(
                        min: subrange.lowerBound,
                        max: subrange.upperBound,
                        tag: tag,
                        isRangeExplicit: isRangeExplicit
                    ),
                    continuation: lengthContinuation
                )

                // Create a sequence generator with this sub-length
                let subSeqGen: ReflectiveGenerator<Any> = .impure(
                    operation: .sequence(length: subLengthGen, gen: elementGen),
                    continuation: { .pure($0) }
                )

                subrangeChoices.append(ReflectiveOperation.PickTuple(
                    siteID: context.rng.next(),
                    id: context.rng.next(),
                    weight: 1,
                    generator: subSeqGen
                ))
            }

            let synthesisedPick: ReflectiveGenerator<Output> = .impure(
                operation: .pick(choices: subrangeChoices),
                continuation: continuation
            )

            return try tuneRecursive(
                synthesisedPick,
                context: context,
                insideSubdividedChooseBits: true,
                predicate: predicate
            )
        }

        // If the length generator uses getSize + bind (the common pattern),
        // try to look one level deeper (only if we haven't already subdivided)
        if !insideSubdividedChooseBits,
           case let .impure(.getSize, getSizeContinuation) = lengthGen
        {
            // Adapt as getSize → pick of subranges, each producing a sequence
            context.depth += 1
            defer { context.depth -= 1 }

            let subranges = (0 ... context.maxSize).split(into: min(4, Int(context.maxSize + 1)))

            var subrangeChoices = ContiguousArray<ReflectiveOperation.PickTuple>()
            subrangeChoices.reserveCapacity(subranges.count)

            for subrange in subranges {
                // Create a size generator for this subrange
                let subSizeGen: ReflectiveGenerator<UInt64> = .impure(
                    operation: .chooseBits(
                        min: subrange.lowerBound,
                        max: subrange.upperBound,
                        tag: .uint64,
                        isRangeExplicit: false
                    ),
                    continuation: { .pure($0 as! UInt64) }
                )

                // Feed the size into the original getSize continuation to produce
                // the actual length generator, then build the sequence
                let subSeqGen: ReflectiveGenerator<Any> = try .impure(
                    operation: .sequence(
                        length: subSizeGen._bind(getSizeContinuation),
                        gen: elementGen
                    ),
                    continuation: { .pure($0) }
                )

                subrangeChoices.append(ReflectiveOperation.PickTuple(
                    siteID: context.rng.next(),
                    id: context.rng.next(),
                    weight: 1,
                    generator: subSeqGen
                ))
            }

            let synthesisedPick: ReflectiveGenerator<Output> = .impure(
                operation: .pick(choices: subrangeChoices),
                continuation: continuation
            )

            return try tuneRecursive(
                synthesisedPick,
                context: context,
                insideSubdividedChooseBits: true,
                predicate: predicate
            )
        }

        // Fallback: tune element generator with composed predicate
        let composedElementPredicate: (Any) -> Bool = { _ in
            // We can't meaningfully compose through the sequence continuation
            // without knowing the full array context, so return true to keep
            // all element branches available for shrinking
            true
        }

        let tunedElementGen = try tuneRecursive(
            elementGen,
            context: context,
            insideSubdividedChooseBits: false,
            predicate: composedElementPredicate
        )

        return .impure(
            operation: .sequence(length: lengthGen, gen: tunedElementGen),
            continuation: continuation
        )
    }

    // MARK: - GetSize

    private static func tuneGetSize<Output>(
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        context: TuningContext,
        predicate: @escaping (Output) -> Bool
    ) throws -> ReflectiveGenerator<Output> {
        context.depth += 1
        defer { context.depth -= 1 }

        let subranges = (0 ... context.maxSize).split(into: min(4, Int(context.maxSize + 1)))

        var subrangeChoices = ContiguousArray<ReflectiveOperation.PickTuple>()
        subrangeChoices.reserveCapacity(subranges.count)

        for subrange in subranges {
            let subGen: ReflectiveGenerator<Any> = .impure(
                operation: .chooseBits(
                    min: subrange.lowerBound,
                    max: subrange.upperBound,
                    tag: .uint64,
                    isRangeExplicit: false
                ),
                continuation: { .pure($0) }
            )
            subrangeChoices.append(ReflectiveOperation.PickTuple(
                siteID: context.rng.next(),
                id: context.rng.next(),
                weight: 1,
                generator: subGen
            ))
        }

        let synthesisedPick: ReflectiveGenerator<Output> = .impure(
            operation: .pick(choices: subrangeChoices),
            continuation: continuation
        )

        return try tuneRecursive(
            synthesisedPick,
            context: context,
            insideSubdividedChooseBits: true,
            predicate: predicate
        )
    }

    // MARK: - Zip

    private static func tuneZip<Output>(
        generators: ContiguousArray<ReflectiveGenerator<Any>>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        context: TuningContext,
        predicate: @escaping (Output) -> Bool
    ) throws -> ReflectiveGenerator<Output> {
        context.depth += 1
        defer { context.depth -= 1 }

        var tunedGens = ContiguousArray<ReflectiveGenerator<Any>>()
        tunedGens.reserveCapacity(generators.count)

        for (index, componentGen) in generators.enumerated() {
            let composedPredicate: (Any) -> Bool = { componentValue in
                do {
                    // Sample all other components randomly, then test full tuple
                    var values = [Any]()
                    values.reserveCapacity(generators.count)

                    for (otherIndex, otherGen) in generators.enumerated() {
                        if otherIndex == index {
                            values.append(componentValue)
                        } else {
                            var rngCopy = Xoshiro256(
                                seed: context.rng.seed,
                                state: context.rng.currentState
                            )
                            guard let otherValue = try ValueInterpreter<Any>.generate(
                                otherGen,
                                maxRuns: 1,
                                using: &rngCopy
                            ) else {
                                return false
                            }
                            values.append(otherValue)
                        }
                    }

                    let nextGen = try continuation(values)
                    let output = try ValueInterpreter<Output>.generate(
                        nextGen,
                        maxRuns: 1,
                        using: &context.rng
                    )
                    return output.map(predicate) ?? false
                } catch {
                    return false
                }
            }

            let tuned = try tuneRecursive(
                componentGen,
                context: context,
                insideSubdividedChooseBits: false,
                predicate: composedPredicate
            )
            tunedGens.append(tuned)
        }

        return .impure(
            operation: .zip(tunedGens),
            continuation: continuation
        )
    }

    // MARK: - Filter

    private static func tuneFilter<Output>(
        subGen: ReflectiveGenerator<Any>,
        fingerprint: UInt64,
        filterType: FilterType,
        filterPredicate: @escaping (Any) -> Bool,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        context: TuningContext
    ) throws -> ReflectiveGenerator<Output> {
        guard filterType != .rejectionSampling else {
            return .impure(
                operation: .filter(
                    gen: subGen,
                    fingerprint: fingerprint,
                    filterType: filterType,
                    predicate: filterPredicate
                ),
                continuation: continuation
            )
        }

        // Use the filter's own predicate to tune the inner generator
        let tunedInner = try tuneRecursive(
            subGen,
            context: context,
            insideSubdividedChooseBits: false,
            predicate: filterPredicate
        )

        return .impure(
            operation: .filter(
                gen: tunedInner,
                fingerprint: fingerprint,
                filterType: filterType,
                predicate: filterPredicate
            ),
            continuation: continuation
        )
    }

    // MARK: - Contramap

    private static func tuneContramap<Output>(
        transform: @escaping (Any) throws -> Any?,
        next: ReflectiveGenerator<Any>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        context: TuningContext,
        predicate: @escaping (Output) -> Bool
    ) throws -> ReflectiveGenerator<Output> {
        let composedPredicate: (Any) -> Bool = { innerValue in
            do {
                let nextGen = try continuation(innerValue)
                let output = try ValueInterpreter<Output>.generate(
                    nextGen,
                    maxRuns: 1,
                    using: &context.rng
                )
                return output.map(predicate) ?? false
            } catch {
                return false
            }
        }

        let tunedNext = try tuneRecursive(
            next,
            context: context,
            insideSubdividedChooseBits: false,
            predicate: composedPredicate
        )

        return .impure(
            operation: .contramap(transform: transform, next: tunedNext),
            continuation: continuation
        )
    }

    // MARK: - Resize

    private static func tuneResize<Output>(
        newSize: UInt64,
        next: ReflectiveGenerator<Any>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        context: TuningContext,
        insideSubdividedChooseBits: Bool,
        predicate: @escaping (Output) -> Bool
    ) throws -> ReflectiveGenerator<Output> {
        let composedPredicate: (Any) -> Bool = { innerValue in
            do {
                let nextGen = try continuation(innerValue)
                let output = try ValueInterpreter<Output>.generate(
                    nextGen,
                    maxRuns: 1,
                    using: &context.rng
                )
                return output.map(predicate) ?? false
            } catch {
                return false
            }
        }

        let tunedNext = try tuneRecursive(
            next,
            context: context,
            insideSubdividedChooseBits: insideSubdividedChooseBits,
            predicate: composedPredicate
        )

        return .impure(
            operation: .resize(newSize: newSize, next: tunedNext),
            continuation: continuation
        )
    }

    // MARK: - Weight Smoothing

    /// Applies Laplace smoothing and temperature scaling to pick weights in a tuned generator.
    ///
    // MARK: - Adaptive Smoothing

    /// Applies per-site temperature scaling based on entropy analysis.
    ///
    /// Forwards to ``AdaptiveSmoothing/smooth(_:epsilon:baseTemperature:maxTemperature:)``.
    public static func smoothAdaptively<Output>(
        _ generator: ReflectiveGenerator<Output>,
        epsilon: Double = 1.0,
        baseTemperature: Double = 1.0,
        maxTemperature: Double = 4.0
    ) -> ReflectiveGenerator<Output> {
        AdaptiveSmoothing.smooth(
            generator,
            epsilon: epsilon,
            baseTemperature: baseTemperature,
            maxTemperature: maxTemperature
        )
    }
}
