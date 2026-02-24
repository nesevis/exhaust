//
//  ChoiceGradientSampling.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/2/2026.
//

/// Eager adaptation interpreter that transforms a generator's pick structure
/// using Choice Gradient Sampling (CGS).
///
/// Adaptation is performed once at creation time via a single top-down recursive
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
/// adapted using *composed predicates* — the current continuation is folded
/// into the predicate so that inner operations always evaluate against the
/// final output.
///
/// `chooseBits` and `getSize` operations are subdivided into synthesised picks
/// of subranges, then adapted through the pick path.
enum ChoiceGradientSampling {

    // MARK: - Context

    final class AdaptationContext {
        let baseSampleCount: UInt64
        let maxSize: UInt64
        var depth: UInt64 = 0
        var rng: Xoshiro256

        init(baseSampleCount: UInt64, maxSize: UInt64, rng: Xoshiro256) {
            self.baseSampleCount = baseSampleCount
            self.maxSize = maxSize
            self.rng = rng
        }

        /// Sample budget decays exponentially with depth to prevent blowup
        /// in deeply nested generators.
        var currentSampleCount: UInt64 {
            guard depth > 0 else { return baseSampleCount }
            return max(1, baseSampleCount / (2 << min(depth - 1, 10)))
        }
    }

    // MARK: - Public API

    /// Adapts a generator so that its pick weights reflect predicate satisfaction rates.
    ///
    /// The transformation is eager — the returned generator has its structure fully
    /// adapted and can be used with any interpreter.
    ///
    /// - Parameters:
    ///   - generator: The generator to adapt.
    ///   - samples: Base number of samples per pick choice (decays with depth).
    ///   - maxSize: Maximum size parameter used when subdividing `getSize`.
    ///   - seed: Optional seed for deterministic adaptation.
    ///   - predicate: The property that generated values should satisfy.
    /// - Returns: An adapted generator with weights biased toward predicate satisfaction.
    static func adapt<Output>(
        _ generator: ReflectiveGenerator<Output>,
        samples: UInt64 = 100,
        maxSize: UInt64 = 100,
        seed: UInt64? = nil,
        predicate: @escaping (Output) -> Bool
    ) throws -> ReflectiveGenerator<Output> {
        let context = AdaptationContext(
            baseSampleCount: samples,
            maxSize: maxSize,
            rng: seed.map(Xoshiro256.init(seed:)) ?? .init()
        )
        return try adaptRecursive(
            generator,
            context: context,
            insideSubdividedChooseBits: false,
            predicate: predicate
        )
    }

    // MARK: - Recursive Engine

    private static func adaptRecursive<Output>(
        _ gen: ReflectiveGenerator<Output>,
        context: AdaptationContext,
        insideSubdividedChooseBits: Bool,
        predicate: @escaping (Output) -> Bool
    ) throws -> ReflectiveGenerator<Output> {
        switch gen {
        case .pure:
            return gen

        case let .impure(op, continuation):
            switch op {
            case let .pick(choices):
                return try adaptPick(
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
                return try adaptChooseBits(
                    lower: lower,
                    upper: upper,
                    tag: tag,
                    isRangeExplicit: isRangeExplicit,
                    continuation: continuation,
                    context: context,
                    predicate: predicate
                )

            case let .sequence(lengthGen, elementGen):
                return try adaptSequence(
                    lengthGen: lengthGen,
                    elementGen: elementGen,
                    continuation: continuation,
                    context: context,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    predicate: predicate
                )

            case .getSize:
                return try adaptGetSize(
                    continuation: continuation,
                    context: context,
                    predicate: predicate
                )

            case let .zip(generators):
                return try adaptZip(
                    generators: generators,
                    continuation: continuation,
                    context: context,
                    predicate: predicate
                )

            case let .filter(subGen, fingerprint, filterPredicate):
                return try adaptFilter(
                    subGen: subGen,
                    fingerprint: fingerprint,
                    filterPredicate: filterPredicate,
                    continuation: continuation,
                    context: context
                )

            case let .contramap(transform, next):
                return try adaptContramap(
                    transform: transform,
                    next: next,
                    continuation: continuation,
                    context: context,
                    predicate: predicate
                )

            case .just, .prune, .resize, .classify:
                return gen
            }
        }
    }

    // MARK: - Pick

    private static func adaptPick<Output>(
        choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        context: AdaptationContext,
        insideSubdividedChooseBits: Bool,
        predicate: @escaping (Output) -> Bool
    ) throws -> ReflectiveGenerator<Output> {
        context.depth += 1
        defer { context.depth -= 1 }

        var adaptedChoices = ContiguousArray<ReflectiveOperation.PickTuple>()
        adaptedChoices.reserveCapacity(choices.count)

        for choice in choices {
            // 1. Create single-branch pick, complete through continuation
            let singleBranchPick: ReflectiveGenerator<Output> = .impure(
                operation: .pick(choices: [choice]),
                continuation: continuation
            )

            // 2. Sample and count predicate successes
            let sampleCount = context.currentSampleCount
            var successCount: UInt64 = 0
            for _ in 0 ..< sampleCount {
                let result = try ValueInterpreter<Output>.generate(
                    singleBranchPick,
                    maxRuns: 1,
                    using: &context.rng
                )
                if let value = result, predicate(value) {
                    successCount += 1
                }
            }

            // 3. Recursively adapt the choice's inner generator
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

            let adaptedInner = try adaptRecursive(
                choice.generator,
                context: context,
                insideSubdividedChooseBits: insideSubdividedChooseBits,
                predicate: composedPredicate
            )

            adaptedChoices.append(ReflectiveOperation.PickTuple(
                id: choice.id,
                weight: successCount,
                generator: adaptedInner
            ))
        }

        // All-zero safety: restore with weight 1 to prevent draw returning nil
        if adaptedChoices.allSatisfy({ $0.weight == 0 }) {
            adaptedChoices = ContiguousArray(adaptedChoices.map {
                ReflectiveOperation.PickTuple(id: $0.id, weight: 1, generator: $0.generator)
            })
        }

        return .impure(
            operation: .pick(choices: adaptedChoices),
            continuation: continuation
        )
    }

    // MARK: - ChooseBits

    private static func adaptChooseBits<Output>(
        lower: UInt64,
        upper: UInt64,
        tag: TypeTag,
        isRangeExplicit: Bool,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        context: AdaptationContext,
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
                id: context.rng.next(),
                weight: 1,
                generator: subGen
            ))
        }

        let synthesisedPick: ReflectiveGenerator<Output> = .impure(
            operation: .pick(choices: subrangeChoices),
            continuation: continuation
        )

        // Re-enter adaptRecursive to weight the synthesised pick
        return try adaptRecursive(
            synthesisedPick,
            context: context,
            insideSubdividedChooseBits: true,
            predicate: predicate
        )
    }

    // MARK: - Sequence

    private static func adaptSequence<Output>(
        lengthGen: ReflectiveGenerator<UInt64>,
        elementGen: ReflectiveGenerator<Any>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        context: AdaptationContext,
        insideSubdividedChooseBits: Bool,
        predicate: @escaping (Output) -> Bool
    ) throws -> ReflectiveGenerator<Output> {
        // Try to subdivide the length generator if it's a chooseBits
        // (only if we haven't already subdivided)
        if !insideSubdividedChooseBits,
           case let .impure(.chooseBits(lower, upper, tag, isRangeExplicit), lengthContinuation) = lengthGen {
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
                    id: context.rng.next(),
                    weight: 1,
                    generator: subSeqGen
                ))
            }

            let synthesisedPick: ReflectiveGenerator<Output> = .impure(
                operation: .pick(choices: subrangeChoices),
                continuation: continuation
            )

            return try adaptRecursive(
                synthesisedPick,
                context: context,
                insideSubdividedChooseBits: true,
                predicate: predicate
            )
        }

        // If the length generator uses getSize + bind (the common pattern),
        // try to look one level deeper (only if we haven't already subdivided)
        if !insideSubdividedChooseBits,
           case let .impure(.getSize, getSizeContinuation) = lengthGen {
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
                let subSeqGen: ReflectiveGenerator<Any> = .impure(
                    operation: .sequence(
                        length: try subSizeGen.bind(getSizeContinuation),
                        gen: elementGen
                    ),
                    continuation: { .pure($0) }
                )

                subrangeChoices.append(ReflectiveOperation.PickTuple(
                    id: context.rng.next(),
                    weight: 1,
                    generator: subSeqGen
                ))
            }

            let synthesisedPick: ReflectiveGenerator<Output> = .impure(
                operation: .pick(choices: subrangeChoices),
                continuation: continuation
            )

            return try adaptRecursive(
                synthesisedPick,
                context: context,
                insideSubdividedChooseBits: true,
                predicate: predicate
            )
        }

        // Fallback: adapt element generator with composed predicate
        let composedElementPredicate: (Any) -> Bool = { elementValue in
            // We can't meaningfully compose through the sequence continuation
            // without knowing the full array context, so return true to keep
            // all element branches available for shrinking
            true
        }

        let adaptedElementGen = try adaptRecursive(
            elementGen,
            context: context,
            insideSubdividedChooseBits: false,
            predicate: composedElementPredicate
        )

        return .impure(
            operation: .sequence(length: lengthGen, gen: adaptedElementGen),
            continuation: continuation
        )
    }

    // MARK: - GetSize

    private static func adaptGetSize<Output>(
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        context: AdaptationContext,
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
                id: context.rng.next(),
                weight: 1,
                generator: subGen
            ))
        }

        let synthesisedPick: ReflectiveGenerator<Output> = .impure(
            operation: .pick(choices: subrangeChoices),
            continuation: continuation
        )

        return try adaptRecursive(
            synthesisedPick,
            context: context,
            insideSubdividedChooseBits: true,
            predicate: predicate
        )
    }

    // MARK: - Zip

    private static func adaptZip<Output>(
        generators: ContiguousArray<ReflectiveGenerator<Any>>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        context: AdaptationContext,
        predicate: @escaping (Output) -> Bool
    ) throws -> ReflectiveGenerator<Output> {
        context.depth += 1
        defer { context.depth -= 1 }

        var adaptedGens = ContiguousArray<ReflectiveGenerator<Any>>()
        adaptedGens.reserveCapacity(generators.count)

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
                            var rngCopy = context.rng
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

            let adapted = try adaptRecursive(
                componentGen,
                context: context,
                insideSubdividedChooseBits: false,
                predicate: composedPredicate
            )
            adaptedGens.append(adapted)
        }

        return .impure(
            operation: .zip(adaptedGens),
            continuation: continuation
        )
    }

    // MARK: - Filter

    private static func adaptFilter<Output>(
        subGen: ReflectiveGenerator<Any>,
        fingerprint: UInt64,
        filterPredicate: @escaping (Any) -> Bool,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        context: AdaptationContext
    ) throws -> ReflectiveGenerator<Output> {
        // Use the filter's own predicate to adapt the inner generator
        let adaptedInner = try adaptRecursive(
            subGen,
            context: context,
            insideSubdividedChooseBits: false,
            predicate: filterPredicate
        )

        return .impure(
            operation: .filter(gen: adaptedInner, fingerprint: fingerprint, predicate: filterPredicate),
            continuation: continuation
        )
    }

    // MARK: - Contramap

    private static func adaptContramap<Output>(
        transform: @escaping (Any) throws -> Any?,
        next: ReflectiveGenerator<Any>,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        context: AdaptationContext,
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

        let adaptedNext = try adaptRecursive(
            next,
            context: context,
            insideSubdividedChooseBits: false,
            predicate: composedPredicate
        )

        return .impure(
            operation: .contramap(transform: transform, next: adaptedNext),
            continuation: continuation
        )
    }
}
