//
//  GeneratorTuning.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/2/2026.
//

import Foundation

/// Offline, one-shot tuning that transforms a generator's pick structure
/// using fitness-weighted sampling inspired by Choice Gradient Sampling (CGS).
///
/// Tuning is performed once at creation time via a single top-down recursive
/// pass. The result is a normal `ReflectiveGenerator` with synthesised pick
/// structure whose weights reflect predicate satisfaction rates. Shrinking is
/// unaffected because the reducer operates on `ChoiceTree`/`ChoiceSequence`
/// and is weight-agnostic.
///
/// ## Algorithm
///
/// At every `pick`, each choice is sampled through the continuation pipeline
/// to measure how often the final output satisfies the predicate. The measured
/// success count becomes the choice's weight. Inner generators are recursively
/// tuned using *composed predicates* — the current continuation is folded
/// into the predicate so that inner operations always evaluate against the
/// final output.
///
/// `chooseBits` and `getSize` operations are subdivided into synthesised picks
/// of subranges, then tuned through the pick path.
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
        /// Convergence detection in `measureAndTunePick` typically stops
        /// well before this cap, so deeper sites still get meaningful signal.
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

    /// Minimum selection probability per choice. Prevents extreme weight ratios
    /// from compounding across depth levels, which would collapse rare-but-valid
    /// deep paths to near-zero probability. The paper (§4.3, Figure 13) shows
    /// that bounding weights to [0.1, 0.9] prevents overfitting and improves
    /// output diversity.
    ///
    /// **Caveat for wide picks:** the floor applies per-choice, so a pick with
    /// many dead branches pays a cost proportional to `deadBranches / totalBranches`.
    /// Binary picks lose at most ~10% of selection probability to the floor, but
    /// e.g. a 20-way pick with 2 valid branches drops valid selection from ~100%
    /// to ~36%. If this becomes a problem, scale the fraction inversely with
    /// branch count (`weightFloorFraction / choiceCount`) to cap total floor
    /// budget at a fixed share of weight regardless of branch count.
    private static let weightFloorFraction: Double = 0.1

    // MARK: - Public API

    /// Probes a generator's structure by running it a few times and checking whether
    /// the resulting choice trees contain any pick sites. If picks are present,
    /// performs full tuning with adaptive smoothing. If not, returns the
    /// generator unchanged — tuning has nothing to attach weights to.
    ///
    /// - Parameters:
    ///   - generator: The generator to probe and possibly tune.
    ///   - probeSeed: Seed for the probe runs (default 0).
    ///   - probeRuns: Number of probe generations to inspect (default 10).
    ///   - minPerChoice: Minimum samples per choice at the deepest pick level (default 30).
    ///   - maxSamples: Upper bound on the computed sample count (default 5000).
    ///   - maxRuns: Planned generation volume. When provided, the tuning budget is
    ///     capped so that tuning doesn't dwarf generation time for small runs.
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
        predicate: @escaping (Output) -> Bool,
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

        let tuned = try tune(generator, samples: samples, maxSize: maxSize, seed: seed, predicate: predicate)
        return smoothAdaptively(tuned)
    }

    /// Tunes a generator so that its pick weights reflect predicate satisfaction rates.
    ///
    /// The transformation is eager — the returned generator has its structure fully
    /// tuned and can be used with any interpreter.
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
        predicate: @escaping (Output) -> Bool,
    ) throws -> ReflectiveGenerator<Output> {
        let rng: Xoshiro256
        if let seed {
            rng = Xoshiro256(seed: seed)
        } else {
            rng = Xoshiro256()
        }
        let context = TuningContext(
            baseSampleCount: samples,
            maxSize: maxSize,
            rng: rng,
        )
        return try tuneRecursive(
            generator,
            context: context,
            insideSubdividedChooseBits: false,
            predicate: predicate,
        )
    }

    // MARK: - Recursive Engine

    private static func tuneRecursive<Output>(
        _ gen: ReflectiveGenerator<Output>,
        context: TuningContext,
        insideSubdividedChooseBits: Bool,
        predicate: @escaping (Output) -> Bool,
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
                    predicate: predicate,
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
                    predicate: predicate,
                )

            case let .sequence(lengthGen, elementGen):
                return try tuneSequence(
                    lengthGen: lengthGen,
                    elementGen: elementGen,
                    continuation: continuation,
                    context: context,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    predicate: predicate,
                )

            case .getSize:
                return try tuneGetSize(
                    continuation: continuation,
                    context: context,
                    predicate: predicate,
                )

            case let .zip(generators):
                return try tuneZip(
                    generators: generators,
                    continuation: continuation,
                    context: context,
                    predicate: predicate,
                )

            case let .filter(subGen, fingerprint, filterType, filterPredicate):
                return try tuneFilter(
                    subGen: subGen,
                    fingerprint: fingerprint,
                    filterType: filterType,
                    filterPredicate: filterPredicate,
                    continuation: continuation,
                    context: context,
                )

            case let .contramap(transform, next):
                return try tuneContramap(
                    transform: transform,
                    next: next,
                    continuation: continuation,
                    context: context,
                    predicate: predicate,
                )

            case let .resize(newSize, next):
                return try tuneResize(
                    newSize: newSize,
                    next: next,
                    continuation: continuation,
                    context: context,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    predicate: predicate,
                )

            case let .unique(subGen, fingerprint, keyExtractor):
                let tunedInner = try tuneRecursive(
                    subGen,
                    context: context,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    predicate: { _ in true },
                )
                return .impure(
                    operation: .unique(gen: tunedInner, fingerprint: fingerprint, keyExtractor: keyExtractor),
                    continuation: continuation,
                )

            case let .recursive(base, extend):
                let tunedBase = try tuneRecursive(
                    base,
                    context: context,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    predicate: { _ in true },
                )
                return .impure(
                    operation: .recursive(base: tunedBase, extend: extend),
                    continuation: continuation,
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
        predicate: @escaping (Output) -> Bool,
    ) throws -> ReflectiveGenerator<Output> {
        context.depth += 1
        defer { context.depth -= 1 }

        let choiceCount = choices.count
        let maxSamples = context.maxSamplesPerSite

        // --- Phase 1: Batched sampling of all choices with convergence ---

        // Per-choice state: independent RNG stream (stored as seed+state tuples
        // since ~Copyable Xoshiro256 can't be stored in Array), accumulators, cache
        var choiceRngStates: [(seed: UInt64, state: Xoshiro256.StateType)] = (0 ..< choiceCount).map {
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
                var rng = Xoshiro256(seed: choiceRngStates[choiceIdx].seed, state: choiceRngStates[choiceIdx].state)
                for _ in totalSampled ..< batchEnd {
                    // Advance RNG to ensure each sample sees a unique state.
                    // Without this, choices with trivial generators (e.g. .just)
                    // leave the RNG frozen — the entire predicate chain may
                    // consist of .pure unwrapping that consumes no randomness,
                    // making all samples identical.
                    _ = rng.next()

                    guard let innerValue = try ValueInterpreter<Any>.generate(
                        choices[choiceIdx].generator, maxRuns: 1, using: &rng,
                    ) else { continue }

                    let success: Bool
                    var output: Output?
                    do {
                        let nextGen = try continuation(innerValue)
                        output = try ValueInterpreter<Output>.generate(
                            nextGen, maxRuns: 1, using: &rng,
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
                    generator: choice.generator,
                ))
                continue
            }

            // The composed predicate checks the cache from Phase 1 first,
            // falling back to full continuation evaluation on cache miss.
            var composedRng = Xoshiro256(seed: choiceRngStates[choiceIdx].seed, state: choiceRngStates[choiceIdx].state)
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
                        using: &composedRng,
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
                predicate: composedPredicate,
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
                generator: tunedInner,
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
                    weight: floor, generator: choice.generator,
                )
            })
        }

        // All-zero safety: restore with weight 1 to prevent draw returning nil
        if tunedChoices.allSatisfy({ $0.weight == 0 }) {
            tunedChoices = ContiguousArray(tunedChoices.map {
                ReflectiveOperation.PickTuple(siteID: $0.siteID, id: $0.id, weight: 1, generator: $0.generator)
            })
        }

        return .impure(
            operation: .pick(choices: tunedChoices),
            continuation: continuation,
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
        predicate: @escaping (Output) -> Bool,
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
                    isRangeExplicit: isRangeExplicit,
                ),
                continuation: { .pure($0) },
            )
            subrangeChoices.append(ReflectiveOperation.PickTuple(
                siteID: context.rng.next(),
                id: context.rng.next(),
                weight: 1,
                generator: subGen,
            ))
        }

        let synthesisedPick: ReflectiveGenerator<Output> = .impure(
            operation: .pick(choices: subrangeChoices),
            continuation: continuation,
        )

        // Re-enter tuneRecursive to weight the synthesised pick
        return try tuneRecursive(
            synthesisedPick,
            context: context,
            insideSubdividedChooseBits: true,
            predicate: predicate,
        )
    }

    // MARK: - Sequence

    private static func tuneSequence<Output>(
        lengthGen: ReflectiveGenerator<UInt64>,
        elementGen: ReflectiveGenerator<Any>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        context: TuningContext,
        insideSubdividedChooseBits: Bool,
        predicate: @escaping (Output) -> Bool,
    ) throws -> ReflectiveGenerator<Output> {
        // Try to subdivide the length generator if it's a chooseBits
        // (only if we haven't already subdivided)
        if !insideSubdividedChooseBits,
           case let .impure(.chooseBits(lower, upper, tag, isRangeExplicit), lengthContinuation) = lengthGen
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
                        isRangeExplicit: isRangeExplicit,
                    ),
                    continuation: lengthContinuation,
                )

                // Create a sequence generator with this sub-length
                let subSeqGen: ReflectiveGenerator<Any> = .impure(
                    operation: .sequence(length: subLengthGen, gen: elementGen),
                    continuation: { .pure($0) },
                )

                subrangeChoices.append(ReflectiveOperation.PickTuple(
                    siteID: context.rng.next(),
                    id: context.rng.next(),
                    weight: 1,
                    generator: subSeqGen,
                ))
            }

            let synthesisedPick: ReflectiveGenerator<Output> = .impure(
                operation: .pick(choices: subrangeChoices),
                continuation: continuation,
            )

            return try tuneRecursive(
                synthesisedPick,
                context: context,
                insideSubdividedChooseBits: true,
                predicate: predicate,
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
                        isRangeExplicit: false,
                    ),
                    continuation: { .pure($0 as! UInt64) },
                )

                // Feed the size into the original getSize continuation to produce
                // the actual length generator, then build the sequence
                let subSeqGen: ReflectiveGenerator<Any> = try .impure(
                    operation: .sequence(
                        length: subSizeGen.bind(getSizeContinuation),
                        gen: elementGen,
                    ),
                    continuation: { .pure($0) },
                )

                subrangeChoices.append(ReflectiveOperation.PickTuple(
                    siteID: context.rng.next(),
                    id: context.rng.next(),
                    weight: 1,
                    generator: subSeqGen,
                ))
            }

            let synthesisedPick: ReflectiveGenerator<Output> = .impure(
                operation: .pick(choices: subrangeChoices),
                continuation: continuation,
            )

            return try tuneRecursive(
                synthesisedPick,
                context: context,
                insideSubdividedChooseBits: true,
                predicate: predicate,
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
            predicate: composedElementPredicate,
        )

        return .impure(
            operation: .sequence(length: lengthGen, gen: tunedElementGen),
            continuation: continuation,
        )
    }

    // MARK: - GetSize

    private static func tuneGetSize<Output>(
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        context: TuningContext,
        predicate: @escaping (Output) -> Bool,
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
                    isRangeExplicit: false,
                ),
                continuation: { .pure($0) },
            )
            subrangeChoices.append(ReflectiveOperation.PickTuple(
                siteID: context.rng.next(),
                id: context.rng.next(),
                weight: 1,
                generator: subGen,
            ))
        }

        let synthesisedPick: ReflectiveGenerator<Output> = .impure(
            operation: .pick(choices: subrangeChoices),
            continuation: continuation,
        )

        return try tuneRecursive(
            synthesisedPick,
            context: context,
            insideSubdividedChooseBits: true,
            predicate: predicate,
        )
    }

    // MARK: - Zip

    private static func tuneZip<Output>(
        generators: ContiguousArray<ReflectiveGenerator<Any>>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        context: TuningContext,
        predicate: @escaping (Output) -> Bool,
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
                            var rngCopy = Xoshiro256(seed: context.rng.seed, state: context.rng.currentState)
                            guard let otherValue = try ValueInterpreter<Any>.generate(
                                otherGen,
                                maxRuns: 1,
                                using: &rngCopy,
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
                        using: &context.rng,
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
                predicate: composedPredicate,
            )
            tunedGens.append(tuned)
        }

        return .impure(
            operation: .zip(tunedGens),
            continuation: continuation,
        )
    }

    // MARK: - Filter

    private static func tuneFilter<Output>(
        subGen: ReflectiveGenerator<Any>,
        fingerprint: UInt64,
        filterType: FilterType,
        filterPredicate: @escaping (Any) -> Bool,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        context: TuningContext,
    ) throws -> ReflectiveGenerator<Output> {
        guard filterType != .rejectionSampling else {
            return .impure(
                operation: .filter(gen: subGen, fingerprint: fingerprint, filterType: filterType, predicate: filterPredicate),
                continuation: continuation,
            )
        }

        // Use the filter's own predicate to tune the inner generator
        let tunedInner = try tuneRecursive(
            subGen,
            context: context,
            insideSubdividedChooseBits: false,
            predicate: filterPredicate,
        )

        return .impure(
            operation: .filter(gen: tunedInner, fingerprint: fingerprint, filterType: filterType, predicate: filterPredicate),
            continuation: continuation,
        )
    }

    // MARK: - Contramap

    private static func tuneContramap<Output>(
        transform: @escaping (Any) throws -> Any?,
        next: ReflectiveGenerator<Any>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        context: TuningContext,
        predicate: @escaping (Output) -> Bool,
    ) throws -> ReflectiveGenerator<Output> {
        let composedPredicate: (Any) -> Bool = { innerValue in
            do {
                let nextGen = try continuation(innerValue)
                let output = try ValueInterpreter<Output>.generate(
                    nextGen,
                    maxRuns: 1,
                    using: &context.rng,
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
            predicate: composedPredicate,
        )

        return .impure(
            operation: .contramap(transform: transform, next: tunedNext),
            continuation: continuation,
        )
    }

    // MARK: - Resize

    private static func tuneResize<Output>(
        newSize: UInt64,
        next: ReflectiveGenerator<Any>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        context: TuningContext,
        insideSubdividedChooseBits: Bool,
        predicate: @escaping (Output) -> Bool,
    ) throws -> ReflectiveGenerator<Output> {
        let composedPredicate: (Any) -> Bool = { innerValue in
            do {
                let nextGen = try continuation(innerValue)
                let output = try ValueInterpreter<Output>.generate(
                    nextGen,
                    maxRuns: 1,
                    using: &context.rng,
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
            predicate: composedPredicate,
        )

        return .impure(
            operation: .resize(newSize: newSize, next: tunedNext),
            continuation: continuation,
        )
    }

    // MARK: - Weight Smoothing

    /// Applies Laplace smoothing and temperature scaling to pick weights in a tuned generator.
    ///
    /// After ``tune`` bakes success counts into pick weights, deeper branches may receive
    /// weight 0 because composed predicates have near-zero success rates during sampling.
    /// This post-processing step recovers dead branches and controls exploration:
    ///
    /// 1. **Laplace smoothing (ε)**: Adds ε to every weight before scaling, ensuring
    ///    branches with zero success count still get non-zero probability.
    /// 2. **Temperature (T)**: Raises smoothed weights to 1/T. T > 1 flattens toward
    ///    uniform (more exploration). T < 1 sharpens toward argmax (more exploitation).
    ///    T = 1 preserves original ratios with the ε offset.
    ///
    /// The transformation walks the generator tree and rescales every reachable pick's
    /// weights to integers summing to ~10000, with a floor of 1 per branch.
    ///
    /// - Parameters:
    ///   - generator: A tuned generator (typically the output of ``tune``).
    ///   - epsilon: Laplace smoothing constant. Default: 1.0
    ///   - temperature: Temperature parameter. Default: 2.0
    /// - Returns: A generator with smoothed pick weights throughout the tree.
    public static func smooth<Output>(
        _ generator: ReflectiveGenerator<Output>,
        epsilon: Double = 1.0,
        temperature: Double = 2.0,
    ) -> ReflectiveGenerator<Output> {
        smoothGenerator(generator, epsilon: epsilon, temperature: temperature)
    }

    private static func smoothGenerator<Output>(
        _ gen: ReflectiveGenerator<Output>,
        epsilon: Double,
        temperature: Double,
    ) -> ReflectiveGenerator<Output> {
        switch gen {
        case .pure:
            return gen
        case let .impure(operation, continuation):
            let smoothed = smoothOperation(operation, epsilon: epsilon, temperature: temperature)
            return .impure(operation: smoothed, continuation: continuation)
        }
    }

    private static func smoothOperation(
        _ op: ReflectiveOperation,
        epsilon: Double,
        temperature: Double,
    ) -> ReflectiveOperation {
        switch op {
        case let .pick(choices):
            let raw = choices.map { pow(Double($0.weight) + epsilon, 1.0 / temperature) }
            let total = raw.reduce(0, +)

            var smoothed = ContiguousArray<ReflectiveOperation.PickTuple>()
            smoothed.reserveCapacity(choices.count)

            for (i, choice) in choices.enumerated() {
                let scaled = max(1, UInt64((raw[i] / total) * 10000))
                smoothed.append(ReflectiveOperation.PickTuple(
                    siteID: choice.siteID,
                    id: choice.id,
                    weight: scaled,
                    generator: smoothGenerator(choice.generator, epsilon: epsilon, temperature: temperature),
                ))
            }

            return .pick(choices: smoothed)

        case let .zip(generators):
            return .zip(ContiguousArray(generators.map {
                smoothGenerator($0, epsilon: epsilon, temperature: temperature)
            }))

        case let .sequence(length, gen):
            return .sequence(
                length: smoothGenerator(length, epsilon: epsilon, temperature: temperature),
                gen: smoothGenerator(gen, epsilon: epsilon, temperature: temperature),
            )

        case let .contramap(transform, next):
            return .contramap(
                transform: transform,
                next: smoothGenerator(next, epsilon: epsilon, temperature: temperature),
            )

        case let .prune(next):
            return .prune(next: smoothGenerator(next, epsilon: epsilon, temperature: temperature))

        case let .resize(newSize, next):
            return .resize(
                newSize: newSize,
                next: smoothGenerator(next, epsilon: epsilon, temperature: temperature),
            )

        case let .filter(gen, fingerprint, filterType, predicate):
            return .filter(
                gen: smoothGenerator(gen, epsilon: epsilon, temperature: temperature),
                fingerprint: fingerprint,
                filterType: filterType,
                predicate: predicate,
            )

        case let .classify(gen, fingerprint, classifiers):
            return .classify(
                gen: smoothGenerator(gen, epsilon: epsilon, temperature: temperature),
                fingerprint: fingerprint,
                classifiers: classifiers,
            )

        case let .unique(gen, fingerprint, keyExtractor):
            return .unique(
                gen: smoothGenerator(gen, epsilon: epsilon, temperature: temperature),
                fingerprint: fingerprint,
                keyExtractor: keyExtractor,
            )

        case let .recursive(base, extend):
            return .recursive(
                base: smoothGenerator(base, epsilon: epsilon, temperature: temperature),
                extend: extend,
            )

        case .chooseBits, .just, .getSize:
            return op
        }
    }

    // MARK: - Pick Site Profile

    /// Statistics about a single pick site in a generator tree.
    public struct SiteStats: CustomStringConvertible {
        public let siteID: UInt64
        public let depth: Int
        public let branchCount: Int
        public let weights: [UInt64]
        /// Shannon entropy in bits, computed from the weight distribution.
        public let entropy: Double
        /// Maximum possible entropy: log₂(branchCount).
        public let maxEntropy: Double
        /// Ratio of actual entropy to maximum (0 = bottleneck, 1 = uniform).
        public let entropyRatio: Double

        // Empirical fields (nil when only static profiling is used)
        public let selectionCounts: [UInt64: Int]?
        public let validityCounts: [UInt64: (selected: Int, valid: Int)]?

        public var description: String {
            let empirical: String
            if let validityCounts {
                let pairs = validityCounts.sorted(by: { $0.key < $1.key })
                    .map { "id \($0.key): \($0.value.valid)/\($0.value.selected)" }
                    .joined(separator: ", ")
                empirical = " validity=[\(pairs)]"
            } else {
                empirical = ""
            }
            return "SiteStats(siteID: \(siteID), depth: \(depth), branches: \(branchCount), " +
                "entropy: \(String(format: "%.2f", entropy))/\(String(format: "%.2f", maxEntropy)), " +
                "ratio: \(String(format: "%.3f", entropyRatio))\(empirical))"
        }
    }

    /// A profile of all pick sites in a generator tree.
    public struct PickSiteProfile: CustomStringConvertible {
        public let sites: [SiteStats]

        public var description: String {
            sites.map(\.description).joined(separator: "\n")
        }
    }

    // MARK: - Static Profile (Level 2)

    /// Profiles all pick sites in a generator, computing entropy from weights.
    ///
    /// This walks the tuned `ReflectiveGenerator` tree and collects statistics
    /// at each `.pick` site: weight distribution, Shannon entropy, and the
    /// entropy ratio (how uniform the distribution is).
    ///
    /// - Parameter generator: The generator to profile (typically the output of ``tune``).
    /// - Returns: A profile containing statistics for every pick site.
    public static func profile(
        _ generator: ReflectiveGenerator<some Any>,
    ) -> PickSiteProfile {
        var sites = [SiteStats]()
        profileGenerator(generator, depth: 0, sites: &sites)
        return PickSiteProfile(sites: sites)
    }

    private static func profileGenerator(
        _ gen: ReflectiveGenerator<some Any>,
        depth: Int,
        sites: inout [SiteStats],
    ) {
        switch gen {
        case .pure:
            return
        case let .impure(operation, _):
            profileOperation(operation, depth: depth, sites: &sites)
        }
    }

    private static func profileOperation(
        _ op: ReflectiveOperation,
        depth: Int,
        sites: inout [SiteStats],
    ) {
        switch op {
        case let .pick(choices):
            guard let firstChoice = choices.first else { return }
            let siteID = firstChoice.siteID
            let weights = choices.map(\.weight)
            let total = Double(weights.reduce(0, +))
            let probs = total > 0 ? weights.map { Double($0) / total } : weights.map { _ in 1.0 / Double(weights.count) }
            let entropy = -probs.filter { $0 > 0 }.reduce(0.0) { $0 + $1 * log2($1) }
            let maxEntropy = log2(Double(choices.count))
            let entropyRatio = maxEntropy > 0 ? entropy / maxEntropy : 1.0

            sites.append(SiteStats(
                siteID: siteID,
                depth: depth,
                branchCount: choices.count,
                weights: weights,
                entropy: entropy,
                maxEntropy: maxEntropy,
                entropyRatio: entropyRatio,
                selectionCounts: nil,
                validityCounts: nil,
            ))

            for choice in choices {
                profileGenerator(choice.generator, depth: depth + 1, sites: &sites)
            }

        case let .zip(generators):
            for gen in generators {
                profileGenerator(gen, depth: depth, sites: &sites)
            }

        case let .sequence(length, gen):
            profileGenerator(length, depth: depth, sites: &sites)
            profileGenerator(gen, depth: depth, sites: &sites)

        case let .contramap(_, next):
            profileGenerator(next, depth: depth, sites: &sites)

        case let .prune(next):
            profileGenerator(next, depth: depth, sites: &sites)

        case let .resize(_, next):
            profileGenerator(next, depth: depth, sites: &sites)

        case let .filter(gen, _, _, _):
            profileGenerator(gen, depth: depth, sites: &sites)

        case let .classify(gen, _, _):
            profileGenerator(gen, depth: depth, sites: &sites)

        case let .unique(gen, _, _):
            profileGenerator(gen, depth: depth, sites: &sites)

        case let .recursive(base, _):
            profileGenerator(base, depth: depth, sites: &sites)

        case .chooseBits, .just, .getSize:
            return
        }
    }

    // MARK: - Empirical Profile (Level 3)

    /// Profiles a generator empirically by generating samples and testing them.
    ///
    /// This combines static weight analysis (Level 2) with empirical data from
    /// actually running the generator: which branches are selected and which
    /// selections lead to valid outputs.
    ///
    /// - Parameters:
    ///   - generator: The generator to profile.
    ///   - predicate: The validity predicate.
    ///   - samples: Number of values to generate for empirical data.
    ///   - seed: Optional seed for reproducibility.
    /// - Returns: A profile with both static entropy and empirical validity data.
    public static func profile<Output>(
        _ generator: ReflectiveGenerator<Output>,
        predicate: @escaping (Output) -> Bool,
        samples: UInt64 = 1000,
        seed: UInt64? = nil,
    ) -> PickSiteProfile {
        // First, get the static profile
        let staticProfile = profile(generator)

        // Generate samples with choice trees
        var iterator = ValueAndChoiceTreeInterpreter(
            generator,
            seed: seed,
            maxRuns: samples,
        )

        // Accumulate per-siteID empirical data
        var selectionCounts = [UInt64: [UInt64: Int]]()
        var validityCounts = [UInt64: [UInt64: (selected: Int, valid: Int)]]()

        while let (value, tree) = try? iterator.next() {
            let isValid = predicate(value)
            collectEmpiricalData(
                from: tree,
                isValid: isValid,
                selectionCounts: &selectionCounts,
                validityCounts: &validityCounts,
            )
        }

        // Merge empirical data with static profile
        let mergedSites = staticProfile.sites.map { site in
            SiteStats(
                siteID: site.siteID,
                depth: site.depth,
                branchCount: site.branchCount,
                weights: site.weights,
                entropy: site.entropy,
                maxEntropy: site.maxEntropy,
                entropyRatio: site.entropyRatio,
                selectionCounts: selectionCounts[site.siteID],
                validityCounts: validityCounts[site.siteID],
            )
        }

        return PickSiteProfile(sites: mergedSites)
    }

    private static func collectEmpiricalData(
        from tree: ChoiceTree,
        isValid: Bool,
        selectionCounts: inout [UInt64: [UInt64: Int]],
        validityCounts: inout [UInt64: [UInt64: (selected: Int, valid: Int)]],
    ) {
        switch tree {
        case let .selected(inner):
            collectEmpiricalData(
                from: inner,
                isValid: isValid,
                selectionCounts: &selectionCounts,
                validityCounts: &validityCounts,
            )

        case let .branch(siteID, _, id, _, choice):
            selectionCounts[siteID, default: [:]][id, default: 0] += 1
            var entry = validityCounts[siteID, default: [:]][id, default: (selected: 0, valid: 0)]
            entry.selected += 1
            if isValid { entry.valid += 1 }
            validityCounts[siteID, default: [:]][id] = entry

            collectEmpiricalData(
                from: choice,
                isValid: isValid,
                selectionCounts: &selectionCounts,
                validityCounts: &validityCounts,
            )

        case let .group(children):
            for child in children {
                collectEmpiricalData(
                    from: child,
                    isValid: isValid,
                    selectionCounts: &selectionCounts,
                    validityCounts: &validityCounts,
                )
            }

        case let .sequence(_, elements, _):
            for element in elements {
                collectEmpiricalData(
                    from: element,
                    isValid: isValid,
                    selectionCounts: &selectionCounts,
                    validityCounts: &validityCounts,
                )
            }

        case let .resize(_, choices):
            for choice in choices {
                collectEmpiricalData(
                    from: choice,
                    isValid: isValid,
                    selectionCounts: &selectionCounts,
                    validityCounts: &validityCounts,
                )
            }

        case .choice, .just, .getSize:
            return
        }
    }

    // MARK: - Adaptive Smoothing

    /// Applies per-site temperature scaling based on entropy analysis.
    ///
    /// Unlike ``smooth`` which applies the same temperature everywhere, this
    /// function computes each pick site's entropy ratio and derives a
    /// site-specific temperature:
    ///
    /// - Bottleneck sites (low entropy ratio) get high temperature → more exploration
    /// - Well-distributed sites (high entropy ratio) get low temperature → preserve tuned weights
    ///
    /// This avoids sacrificing validity at well-distributed sites while still
    /// recovering dead branches at bottleneck sites.
    ///
    /// - Parameters:
    ///   - generator: A tuned generator (typically the output of ``tune``).
    ///   - epsilon: Laplace smoothing constant. Default: 1.0
    ///   - baseTemperature: Temperature for well-distributed sites. Default: 1.0
    ///   - maxTemperature: Temperature for bottleneck sites. Default: 4.0
    /// - Returns: A generator with adaptively smoothed pick weights.
    public static func smoothAdaptively<Output>(
        _ generator: ReflectiveGenerator<Output>,
        epsilon: Double = 1.0,
        baseTemperature: Double = 1.0,
        maxTemperature: Double = 4.0,
    ) -> ReflectiveGenerator<Output> {
        smoothAdaptiveGenerator(
            generator,
            epsilon: epsilon,
            baseTemperature: baseTemperature,
            maxTemperature: maxTemperature,
        )
    }

    private static func smoothAdaptiveGenerator<Output>(
        _ gen: ReflectiveGenerator<Output>,
        epsilon: Double,
        baseTemperature: Double,
        maxTemperature: Double,
    ) -> ReflectiveGenerator<Output> {
        switch gen {
        case .pure:
            return gen
        case let .impure(operation, continuation):
            let smoothed = smoothAdaptiveOperation(
                operation,
                epsilon: epsilon,
                baseTemperature: baseTemperature,
                maxTemperature: maxTemperature,
            )
            return .impure(operation: smoothed, continuation: continuation)
        }
    }

    private static func smoothAdaptiveOperation(
        _ op: ReflectiveOperation,
        epsilon: Double,
        baseTemperature: Double,
        maxTemperature: Double,
    ) -> ReflectiveOperation {
        switch op {
        case let .pick(choices):
            // Compute Shannon entropy to measure how uniform the weight distribution is
            let totalWeight = choices.reduce(into: UInt64(0)) { $0 += $1.weight }
            let entropy: Double
            if totalWeight > 0 {
                let total = Double(totalWeight)
                entropy = -choices.reduce(into: 0.0) { sum, choice in
                    let p = Double(choice.weight) / total
                    if p > 0 { sum += p * log2(p) }
                }
            } else {
                entropy = log2(Double(choices.count))
            }
            let maxEntropy = log2(Double(choices.count))
            let entropyRatio = maxEntropy > 0 ? entropy / maxEntropy : 1.0

            // Bottleneck sites (low entropy) get high temperature; uniform sites stay cool
            let siteTemp = baseTemperature + (maxTemperature - baseTemperature) * (1.0 - entropyRatio)

            // Apply Laplace smoothing with site-specific temperature: w' = (w + ε)^(1/T)
            let raw = choices.map { pow(Double($0.weight) + epsilon, 1.0 / siteTemp) }
            let rawTotal = raw.reduce(0, +)

            let smoothed = ContiguousArray(choices.enumerated().map { i, choice in
                ReflectiveOperation.PickTuple(
                    siteID: choice.siteID,
                    id: choice.id,
                    weight: max(1, UInt64(raw[i] / rawTotal * 10000)),
                    generator: smoothAdaptiveGenerator(
                        choice.generator,
                        epsilon: epsilon,
                        baseTemperature: baseTemperature,
                        maxTemperature: maxTemperature,
                    ),
                )
            })

            return .pick(choices: smoothed)

        case let .zip(generators):
            return .zip(ContiguousArray(generators.map {
                smoothAdaptiveGenerator(
                    $0,
                    epsilon: epsilon,
                    baseTemperature: baseTemperature,
                    maxTemperature: maxTemperature,
                )
            }))

        case let .sequence(length, gen):
            return .sequence(
                length: smoothAdaptiveGenerator(length, epsilon: epsilon, baseTemperature: baseTemperature, maxTemperature: maxTemperature),
                gen: smoothAdaptiveGenerator(gen, epsilon: epsilon, baseTemperature: baseTemperature, maxTemperature: maxTemperature),
            )

        case let .contramap(transform, next):
            return .contramap(
                transform: transform,
                next: smoothAdaptiveGenerator(next, epsilon: epsilon, baseTemperature: baseTemperature, maxTemperature: maxTemperature),
            )

        case let .prune(next):
            return .prune(next: smoothAdaptiveGenerator(next, epsilon: epsilon, baseTemperature: baseTemperature, maxTemperature: maxTemperature))

        case let .resize(newSize, next):
            return .resize(
                newSize: newSize,
                next: smoothAdaptiveGenerator(next, epsilon: epsilon, baseTemperature: baseTemperature, maxTemperature: maxTemperature),
            )

        case let .filter(gen, fingerprint, filterType, predicate):
            return .filter(
                gen: smoothAdaptiveGenerator(gen, epsilon: epsilon, baseTemperature: baseTemperature, maxTemperature: maxTemperature),
                fingerprint: fingerprint,
                filterType: filterType,
                predicate: predicate,
            )

        case let .classify(gen, fingerprint, classifiers):
            return .classify(
                gen: smoothAdaptiveGenerator(gen, epsilon: epsilon, baseTemperature: baseTemperature, maxTemperature: maxTemperature),
                fingerprint: fingerprint,
                classifiers: classifiers,
            )

        case let .unique(gen, fingerprint, keyExtractor):
            return .unique(
                gen: smoothAdaptiveGenerator(gen, epsilon: epsilon, baseTemperature: baseTemperature, maxTemperature: maxTemperature),
                fingerprint: fingerprint,
                keyExtractor: keyExtractor,
            )

        case let .recursive(base, extend):
            return .recursive(
                base: smoothAdaptiveGenerator(base, epsilon: epsilon, baseTemperature: baseTemperature, maxTemperature: maxTemperature),
                extend: extend,
            )

        case .chooseBits, .just, .getSize:
            return op
        }
    }
}
