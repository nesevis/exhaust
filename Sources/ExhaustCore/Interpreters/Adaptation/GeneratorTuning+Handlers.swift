//
//  GeneratorTuning+Handlers.swift
//  Exhaust
//
//  Created by Chris Kolbu on 25/3/2026.
//

import Foundation

extension GeneratorTuning {
    // MARK: - Pick

    static func measureAndTunePick<Output>(
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

    static func tuneChooseBits<Output>(
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

    static func tuneSequence<Output>(
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

    static func tuneGetSize<Output>(
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

    static func tuneZip<Output>(
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

    static func tuneFilter<Output>(
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

    static func tuneContramap<Output>(
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

    static func tuneResize<Output>(
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
}
