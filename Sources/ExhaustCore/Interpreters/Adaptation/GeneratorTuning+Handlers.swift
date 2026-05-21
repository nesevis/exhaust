//
//  GeneratorTuning+Handlers.swift
//  Exhaust
//
//  Created by Chris Kolbu on 25/3/2026.
//

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

extension GeneratorTuning {
    // MARK: - Fitness Measurement

    /// Accumulated sampling results from Phase 1 of ``measureAndTunePick(_:continuation:context:insideSubdividedChooseBits:predicate:)``.
    private struct FitnessMeasurement {
        /// Number of predicate-passing samples per choice index.
        var successCounts: [UInt64]
        /// Frequency distribution of valid outputs per choice index, for entropy weighting.
        var outputFrequencies: [[AnyHashable: UInt64]]
        /// Final RNG states per choice index, for deterministic Phase 2 cache fallback.
        var rngStates: [(seed: UInt64, state: Xoshiro256.StateType)]
        /// Cache of inner-value → predicate result from Phase 1, for Phase 2 composed predicate.
        var continuationCaches: [[AnyHashable: Bool]]
    }

    /// Samples each choice in `choices` with independent RNG streams and measures success rates and output diversity.
    ///
    /// Runs until the maximum sample budget is consumed or the normalized success distribution converges. Returns a ``FitnessMeasurement`` with per-choice accumulators for use in Phase 2 tuning.
    private static func measureFitness<Output>(
        choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        continuation: @escaping (Any) throws -> Generator<Output>,
        context: TuningContext,
        predicate: @escaping (Output) -> Bool
    ) throws -> FitnessMeasurement {
        let choiceCount = choices.count
        let maxSamples = context.maxSamplesPerSite

        // Per-choice state: independent RNG stream (stored as seed+state tuples since ~Copyable Xoshiro256 can't be stored in Array), accumulators, cache
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

        // Scale minimum samples with depth — deep sites shouldn't be forced to the full 40-sample floor when their cap is already low.
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
                    // Without this, choices with trivial generators (for example .just)
                    // leave the RNG frozen — the entire predicate chain may consist of .pure unwrapping that consumes no randomness, making all samples identical.
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

            // Unambiguous early exit: if one choice has ≥80% success rate and another has 0%, the signal is clear — stop without waiting for the second convergence check (which needs one more batch to see the shift stabilize).
            if isTrivial == false {
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

        return FitnessMeasurement(
            successCounts: successCounts,
            outputFrequencies: outputFrequencies,
            rngStates: choiceRngStates,
            continuationCaches: continuationCaches
        )
    }

    // MARK: - Pick

    /// Tunes a pick operation in two phases: Phase 1 samples each branch to measure success rate and output diversity via ``measureFitness(choices:continuation:context:predicate:)``, then Phase 2 recursively tunes each surviving branch's inner generator with a composed predicate backed by the Phase 1 cache.
    ///
    /// Branches with zero successes are assigned weight 0 (skipped) unless all branches scored zero, in which case uniform weights are restored. Surviving branches receive entropy-weighted fitness scores and a minimum weight floor to prevent exponential probability collapse across depth.
    static func measureAndTunePick<Output>(
        choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        branchCount: UInt64,
        continuation: @escaping (Any) throws -> Generator<Output>,
        context: TuningContext,
        insideSubdividedChooseBits: Bool,
        predicate: @escaping (Output) -> Bool
    ) throws -> Generator<Output> {
        context.depth += 1
        defer { context.depth -= 1 }

        let choiceCount = choices.count

        let measurement = try measureFitness(
            choices: choices,
            continuation: continuation,
            context: context,
            predicate: predicate
        )
        let successCounts = measurement.successCounts
        let outputFrequencies = measurement.outputFrequencies
        let choiceRngStates = measurement.rngStates
        let continuationCaches = measurement.continuationCaches

        context.rng.jump()

        var tunedChoices = ContiguousArray<ReflectiveOperation.PickTuple>()
        tunedChoices.reserveCapacity(choiceCount)

        // Only skip dominated branches if at least one branch has positive successes. When all branches scored 0, the all-zero fallback will restore weight 1, so those branches need tuned inner generators.
        let hasAnySuccess = successCounts.contains(where: { $0 > 0 })

        for choiceIdx in 0 ..< choiceCount {
            let choice = choices[choiceIdx]

            // Skip recursive tuning for dominated branches — their weight will be 0 and they won't be selected during generation.
            if hasAnySuccess, successCounts[choiceIdx] == 0 {
                tunedChoices.append(ReflectiveOperation.PickTuple(
                    fingerprint: choice.fingerprint,
                    id: choice.id,
                    weight: 0,
                    generator: choice.generator
                ))
                continue
            }

            // The composed predicate checks the cache from Phase 1 first, falling back to full continuation evaluation on cache miss.
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

            // Specification entropy weighting: reward branches that produce diverse valid outputs, not just frequent ones. Shannon entropy from the empirical frequency distribution captures both frequency and diversity: two branches may each produce 10 distinct outputs, but if one concentrates 90% of mass on a single value the entropy will be low, correctly down-weighting it.
            // The +1 offset ensures branches with a single valid output still receive weight proportional to their success count.
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
                fingerprint: choice.fingerprint,
                id: choice.id,
                weight: weight,
                generator: tunedInner
            ))
        }

        // Weight floor: bound each choice's selection probability to at least weightFloorFraction. This prevents extreme ratios from compounding multiplicatively across depth (for example 0.9^5 leaf bias at every level would collapse h5 BST probability to 0.00001%).
        let totalWeight = tunedChoices.reduce(UInt64(0)) { $0 + $1.weight }
        if totalWeight > 0 {
            let floor = max(UInt64(1), UInt64(Double(totalWeight) * weightFloorFraction))
            tunedChoices = ContiguousArray(tunedChoices.map { choice in
                guard choice.weight < floor else { return choice }
                return ReflectiveOperation.PickTuple(
                    fingerprint: choice.fingerprint, id: choice.id,
                    weight: floor,
                    generator: choice.generator
                )
            })
        }

        // All-zero safety: restore with weight 1 to prevent draw returning nil
        if tunedChoices.allSatisfy({ $0.weight == 0 }) {
            tunedChoices = ContiguousArray(tunedChoices.map {
                ReflectiveOperation.PickTuple(
                    fingerprint: $0.fingerprint,
                    id: $0.id,
                    weight: 1,
                    generator: $0.generator
                )
            })
        }

        return .impure(
            operation: .pick(choices: tunedChoices, branchCount: branchCount),
            continuation: continuation
        )
    }

    // MARK: - ChooseBits

    /// Subdivides a ``ReflectiveOperation/chooseBits`` range into up to four subrange picks, then delegates to ``tuneRecursive(_:context:insideSubdividedChooseBits:predicate:)`` to weight them.
    ///
    /// Unlike picks, chooseBits has no natural branch structure to measure fitness against. Subdivision creates synthetic branches so the same Phase 1/Phase 2 pick-tuning pipeline can bias sampling toward productive subranges.
    static func tuneChooseBits<Output>(
        lower: UInt64,
        upper: UInt64,
        tag: TypeTag,
        isRangeExplicit: Bool,
        scaling: ChooseBitsScaling?,
        continuation: @escaping (Any) throws -> Generator<Output>,
        context: TuningContext,
        predicate: @escaping (Output) -> Bool
    ) throws -> Generator<Output> {
        context.depth += 1
        defer { context.depth -= 1 }

        guard let (choices, branchCount) = SharedInterpreterHelpers.subdivideChooseBits(
            lower: lower, upper: upper, tag: tag,
            isRangeExplicit: isRangeExplicit, scaling: scaling,
            makeFingerprint: { context.rng.next() }
        ) else {
            return .impure(
                operation: .chooseBits(min: lower, max: upper, tag: tag, isRangeExplicit: isRangeExplicit, scaling: scaling),
                continuation: continuation
            )
        }

        let synthesisedPick: Generator<Output> = .impure(
            operation: .pick(choices: choices, branchCount: branchCount),
            continuation: continuation
        )

        return try tuneRecursive(
            synthesisedPick,
            context: context,
            insideSubdividedChooseBits: true,
            predicate: predicate
        )
    }

    // MARK: - Sequence

    /// Tunes a sequence generator by subdividing the length range into up to four subranges, each producing a full sequence, then weighting them via ``measureAndTunePick(_:branchCount:continuation:context:insideSubdividedChooseBits:predicate:)``.
    ///
    /// Handles both explicit ``ReflectiveOperation/chooseBits`` length generators and the common ``ReflectiveOperation/getSize``-then-bind pattern. Falls back to tuning only the element generator with an always-true predicate when neither pattern matches, because element fitness cannot be meaningfully evaluated without the full array context.
    static func tuneSequence<Output>(
        lengthGen: Generator<UInt64>,
        elementGen: AnyGenerator,
        continuation: @escaping (Any) throws -> Generator<Output>,
        context: TuningContext,
        insideSubdividedChooseBits: Bool,
        predicate: @escaping (Output) -> Bool
    ) throws -> Generator<Output> {
        // Try to subdivide the length generator if it's a chooseBits (only if we haven't already subdivided)
        if insideSubdividedChooseBits == false,
           case let .impure(
               .chooseBits(lower, upper, tag, isRangeExplicit, scaling),
               lengthContinuation
           ) = lengthGen
        {
            context.depth += 1
            defer { context.depth -= 1 }

            let rangeSize = (lower ... upper).saturatingCount
            let subrangeCount = min(4, Int(min(rangeSize, UInt64(Int.max))))
            let subranges = (lower ... upper).split(into: subrangeCount)

            let branchCount = UInt64(subranges.count)

            var subrangeChoices = ContiguousArray<ReflectiveOperation.PickTuple>()
            subrangeChoices.reserveCapacity(subranges.count)

            for (index, subrange) in subranges.enumerated() {
                // Create a sub-length generator for this subrange
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

                // Create a sequence generator with this sub-length
                let subSeqGen: AnyGenerator = .impure(
                    operation: .sequence(length: subLengthGen, gen: elementGen),
                    continuation: { .pure($0) }
                )

                subrangeChoices.append(ReflectiveOperation.PickTuple(
                    fingerprint: context.rng.next(),
                    id: UInt64(index),
                    weight: 1,
                    generator: subSeqGen
                ))
            }

            let synthesisedPick: Generator<Output> = .impure(
                operation: .pick(choices: subrangeChoices, branchCount: branchCount),
                continuation: continuation
            )

            return try tuneRecursive(
                synthesisedPick,
                context: context,
                insideSubdividedChooseBits: true,
                predicate: predicate
            )
        }

        // If the length generator uses getSize + bind (the common pattern), try to look one level deeper (only if we haven't already subdivided)
        if insideSubdividedChooseBits == false,
           case let .impure(.getSize, getSizeContinuation) = lengthGen
        {
            // Adapt as getSize → pick of subranges, each producing a sequence
            context.depth += 1
            defer { context.depth -= 1 }

            let subranges = (0 ... context.maxSize).split(into: min(4, Int(context.maxSize + 1)))

            let branchCount = UInt64(subranges.count)

            var subrangeChoices = ContiguousArray<ReflectiveOperation.PickTuple>()
            subrangeChoices.reserveCapacity(subranges.count)

            for (index, subrange) in subranges.enumerated() {
                // Create a size generator for this subrange
                let subSizeGen: Generator<UInt64> = .impure(
                    operation: .chooseBits(
                        min: subrange.lowerBound,
                        max: subrange.upperBound,
                        tag: .uint64,
                        isRangeExplicit: false
                    ),
                    continuation: { .pure($0 as! UInt64) }
                )

                // Feed the size into the original getSize continuation to produce the actual length generator, then build the sequence
                let subSeqGen: AnyGenerator = try .impure(
                    operation: .sequence(
                        length: subSizeGen.bindReified(getSizeContinuation),
                        gen: elementGen
                    ),
                    continuation: { .pure($0) }
                )

                subrangeChoices.append(ReflectiveOperation.PickTuple(
                    fingerprint: context.rng.next(),
                    id: UInt64(index),
                    weight: 1,
                    generator: subSeqGen
                ))
            }

            let synthesisedPick: Generator<Output> = .impure(
                operation: .pick(choices: subrangeChoices, branchCount: branchCount),
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
            // We can't meaningfully compose through the sequence continuation without knowing the full array context, so return true to keep all element branches available for reduction
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

    /// Subdivides the size range (0 to ``TuningContext/maxSize``) into up to four subranges and tunes them as a synthesized pick.
    ///
    /// The ``ReflectiveOperation/getSize`` operation itself is not a tunable choice -- it just reads the current size parameter. Subdivision converts it into a pick so that CGS can bias toward size subranges that produce more predicate-passing outputs.
    static func tuneGetSize<Output>(
        continuation: @escaping (Any) throws -> Generator<Output>,
        context: TuningContext,
        predicate: @escaping (Output) -> Bool
    ) throws -> Generator<Output> {
        context.depth += 1
        defer { context.depth -= 1 }

        guard let (choices, branchCount) = SharedInterpreterHelpers.subdivideChooseBits(
            lower: 0, upper: context.maxSize, tag: .uint64,
            isRangeExplicit: false,
            makeFingerprint: { context.rng.next() }
        ) else {
            return .impure(
                operation: .getSize,
                continuation: continuation
            )
        }

        let synthesisedPick: Generator<Output> = .impure(
            operation: .pick(choices: choices, branchCount: branchCount),
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

    /// Tunes each component generator of a zip independently by composing a predicate that samples the other components randomly and tests the full tuple.
    ///
    /// Each component's predicate holds its candidate value fixed and draws the remaining values from the other (untuned) generators, so tuning decisions for one component are not conditioned on another component's tuned distribution.
    static func tuneZip<Output>(
        generators: ContiguousArray<AnyGenerator>,
        continuation: @escaping (Any) throws -> Generator<Output>,
        context: TuningContext,
        predicate: @escaping (Output) -> Bool
    ) throws -> Generator<Output> {
        context.depth += 1
        defer { context.depth -= 1 }

        var tunedGens = ContiguousArray<AnyGenerator>()
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

    /// Tunes the inner generator of a filter operation using the filter predicate as the fitness function.
    ///
    /// Skips tuning if the filter already has a tuned generator or uses rejection sampling, since both indicate CGS has already run or is inapplicable. Only the candidate-producing generator is tuned -- the filter predicate itself is not modified.
    static func tuneFilter<Output>(
        subGen: AnyGenerator,
        fingerprint: UInt64,
        filterType: FilterType,
        filterPredicate: @escaping (Any) -> Bool,
        sourceLocation: FilterSourceLocation,
        tuned: AnyGenerator?,
        continuation: @escaping (Any) throws -> Generator<Output>,
        context: TuningContext
    ) throws -> Generator<Output> {
        if tuned != nil || filterType == .rejectionSampling {
            return .impure(
                operation: .filter(
                    gen: subGen,
                    fingerprint: fingerprint,
                    filterType: filterType,
                    predicate: filterPredicate,
                    tuned: tuned,
                    sourceLocation: sourceLocation
                ),
                continuation: continuation
            )
        }

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
                predicate: filterPredicate,
                tuned: nil,
                sourceLocation: sourceLocation
            ),
            continuation: continuation
        )
    }

    // MARK: - Contramap

    /// Tunes the inner generator of a contramap by composing the downstream predicate through the continuation.
    ///
    /// The backward mapping (contramap transform) is preserved unchanged -- only the generator feeding into it is tuned. The composed predicate evaluates the full continuation chain to determine whether an inner value ultimately produces a predicate-passing output.
    static func tuneContramap<Output>(
        transform: @escaping (Any) throws -> Any?,
        next: AnyGenerator,
        continuation: @escaping (Any) throws -> Generator<Output>,
        context: TuningContext,
        predicate: @escaping (Output) -> Bool
    ) throws -> Generator<Output> {
        let composedPredicate = SharedInterpreterHelpers.composedPredicate(
            continuation: continuation,
            context: context,
            predicate: predicate
        )

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

    /// Tunes the inner generator under the overridden size, preserving the resize wrapper.
    ///
    /// The composed predicate threads through the continuation so inner values are evaluated in the context of the full downstream pipeline. The ``insideSubdividedChooseBits`` flag propagates inward to prevent double subdivision of already-split ranges.
    static func tuneResize<Output>(
        newSize: UInt64,
        next: AnyGenerator,
        continuation: @escaping (Any) throws -> Generator<Output>,
        context: TuningContext,
        insideSubdividedChooseBits: Bool,
        predicate: @escaping (Output) -> Bool
    ) throws -> Generator<Output> {
        let composedPredicate = SharedInterpreterHelpers.composedPredicate(
            continuation: continuation,
            context: context,
            predicate: predicate
        )

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

    // MARK: - Prune

    /// Tunes the inner generator of a prune operation, preserving the prune wrapper.
    ///
    /// Pruning affects reduction behavior (marking subtrees as reducible to nil), not generation weights, so tuning passes through to the inner generator with a continuation-composed predicate.
    static func tunePrune<Output>(
        next: AnyGenerator,
        continuation: @escaping (Any) throws -> Generator<Output>,
        context: TuningContext,
        insideSubdividedChooseBits: Bool,
        predicate: @escaping (Output) -> Bool
    ) throws -> Generator<Output> {
        let composedPredicate = SharedInterpreterHelpers.composedPredicate(
            continuation: continuation,
            context: context,
            predicate: predicate
        )

        let tunedNext = try tuneRecursive(
            next,
            context: context,
            insideSubdividedChooseBits: insideSubdividedChooseBits,
            predicate: composedPredicate
        )

        return .impure(
            operation: .prune(next: tunedNext),
            continuation: continuation
        )
    }

    // MARK: - Classify

    /// Tunes the inner generator of a classify operation, preserving the classifiers.
    ///
    /// Classification is purely observational -- it labels outputs without affecting the generation distribution -- so tuning passes through to the inner generator with a continuation-composed predicate. The classifier predicates are not used as fitness functions.
    static func tuneClassify<Output>(
        subGen: AnyGenerator,
        fingerprint: UInt64,
        classifiers: [(label: String, predicate: (Any) -> Bool)],
        continuation: @escaping (Any) throws -> Generator<Output>,
        context: TuningContext,
        insideSubdividedChooseBits: Bool,
        predicate: @escaping (Output) -> Bool
    ) throws -> Generator<Output> {
        let composedPredicate = SharedInterpreterHelpers.composedPredicate(
            continuation: continuation,
            context: context,
            predicate: predicate
        )

        let tunedInner = try tuneRecursive(
            subGen,
            context: context,
            insideSubdividedChooseBits: insideSubdividedChooseBits,
            predicate: composedPredicate
        )

        return .impure(
            operation: .classify(
                gen: tunedInner,
                fingerprint: fingerprint,
                classifiers: classifiers
            ),
            continuation: continuation
        )
    }
}
