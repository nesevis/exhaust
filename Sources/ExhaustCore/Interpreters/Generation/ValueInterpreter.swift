//
//  ValueInterpreter.swift
//  Exhaust
//
//  Created by Chris Kolbu on 27/7/2025.
//

// MARK: - Academic Background

//
// Implements the `generate` interpretation G⟦·⟧ (Goldstein section 3.3.3, Fig 4.3 for the reflective version). Pure forward pass that consumes PRNG entropy to produce values — no randomness capture.

/// Produces only a value (no ``ChoiceTree``), used by ``ValueAndChoiceTreeInterpreter/nextValueOnly()`` for tree-free sampling when only the output is needed.
///
/// PRNG consumption is identical to ``ValueAndChoiceTreeInterpreter`` so a failing run can be reproduced with full tree construction.
package struct ValueInterpreter<Element>: ~Copyable, ExhaustIterator {
    let generator: Generator<Element>
    private var erasedGenerator: AnyGenerator?
    private var context: GenerationContext

    /// Creates a value-only interpreter for the given generator with optional seed, run cap, and size override.
    public init(
        _ generator: Generator<Element>,
        seed: UInt64? = nil,
        maxRuns: UInt64? = nil,
        sizeOverride: UInt64? = nil
    ) {
        self.generator = generator
        let baseSeed: UInt64
        if let seed {
            baseSeed = seed
        } else {
            var rng = SystemRandomNumberGenerator()
            baseSeed = rng.next()
        }
        context = .init(
            maxRuns: maxRuns ?? 100,
            baseSeed: baseSeed,
            isFixed: false,
            size: sizeOverride ?? 0,
            prng: Xoshiro256(seed: baseSeed)
        )
    }

    public mutating func next() throws -> Element? {
        guard context.runs < context.maxRuns else {
            return nil
        }

        // Per-run seed derivation: each run gets an independent PRNG
        if context.isFixed == false {
            context.prng = Xoshiro256.derive(from: context.baseSeed, at: context.runs)
        }

        defer { context.runs += 1 }
        if erasedGenerator == nil {
            erasedGenerator = generator.erase()
        }

        do {
            // swiftlint:disable:next force_cast
            return try Self.generateRecursiveAny(erasedGenerator!, with: (), context: &context) as! Element?
        } catch GeneratorError.uniqueBudgetExhausted {
            ExhaustLog.warning(
                category: .generation,
                event: "uniqueness_budget_exhausted",
                metadata: [
                    "unique_count": "\(context.runs)",
                    "requested": "\(context.maxRuns)",
                ]
            )
            context.runs = context.maxRuns
            return nil
        } catch GeneratorError.sparseValidityCondition {
            ExhaustLog.warning(
                category: .generation,
                event: "sparse_validity_condition",
                metadata: [
                    "run": "\(context.runs)",
                ]
            )
            return nil
        }
    }

    // MARK: - Generator implementation

    static func generate<Output>(
        _ gen: Generator<Output>,
        initialSize: UInt64 = 0,
        maxRuns: UInt64,
        using rng: inout Xoshiro256
    ) throws -> Output? {
        let baseSeed = rng.seed
        var context = GenerationContext(
            maxRuns: maxRuns,
            baseSeed: baseSeed,
            isFixed: false,
            size: initialSize,
            prng: Xoshiro256(seed: 0),
            runs: initialSize
        )
        swap(&rng, &context.prng)
        let result = try generateRecursive(gen, with: (), context: &context)
        swap(&rng, &context.prng)
        return result
    }

    // MARK: - Recursive Engine

    /// Typed entry point that erases the generator once at the boundary and casts the result.
    static func generateRecursive<Output>(
        _ gen: Generator<Output>,
        with inputValue: Any,
        context: inout GenerationContext
    ) throws -> Output? {
        // swiftlint:disable:next force_cast
        try generateRecursiveAny(gen.erase(), with: inputValue, context: &context) as! Output?
    }

    /// Non-generic recursive engine. One specialization in the binary regardless of Output type.
    ///
    /// The outer switch matches `.impure(.<operation>, continuation)` directly, enabling single-level dispatch without an intermediate operation variable.
    static func generateRecursiveAny(
        _ gen: AnyGenerator,
        with inputValue: Any,
        context: inout GenerationContext
    ) throws -> Any? {
        switch gen {
            case let .pure(value):
                return value

        // MARK: chooseBits

            case let .impure(operation: .chooseBits(min, max, tag, _, scaling, _), continuation):
                let effectiveRange: ClosedRange<UInt64>
                if let scaling {
                    let size = consumeSize(&context)
                    effectiveRange = Gen.applyScaling(
                        min: min, max: max, tag: tag, scaling: scaling, size: size
                    )
                } else {
                    effectiveRange = min ... max
                }
                let rawBits = context.prng.next(in: effectiveRange)
                let randomBits: Any = tag.isFloatingPoint
                    ? tag.linearlyDistributed(rawBits: rawBits, in: effectiveRange)
                    : rawBits
                let nextGen = try continuation(randomBits)
                if case let .pure(final) = nextGen { return final }
                return try generateRecursiveAny(nextGen, with: inputValue, context: &context)

        // MARK: just

            case let .impure(operation: .just(value), continuation):
                let nextGen = try continuation(value)
                if case let .pure(final) = nextGen { return final }
                return try generateRecursiveAny(nextGen, with: inputValue, context: &context)

        // MARK: getSize

            case .impure(operation: .getSize, let continuation):
                let size = consumeSize(&context)
                let nextGen = try continuation(size)
                if case let .pure(final) = nextGen { return final }
                return try generateRecursiveAny(nextGen, with: inputValue, context: &context)

        // MARK: contramap

            case let .impure(operation: .contramap(_, innerGen), continuation):
                guard let value = try generateRecursiveAny(innerGen, with: inputValue, context: &context) else {
                    return nil
                }
                let nextGen = try continuation(value)
                if case let .pure(final) = nextGen { return final }
                return try generateRecursiveAny(nextGen, with: inputValue, context: &context)

        // MARK: prune

            case let .impure(operation: .prune(innerGen), continuation):
                // Inert guard: forward generation never prunes (reflection-only), and forward inputValue is never Optional.none — kept for symmetry with the reflection/materializer handlers.
                guard let wrappedValue = InterpreterWrapperHandlers.unwrapPruneInput(inputValue) else {
                    return nil
                }
                guard let value = try generateRecursiveAny(innerGen, with: wrappedValue, context: &context) else {
                    return nil
                }
                let nextGen = try continuation(value)
                if case let .pure(final) = nextGen { return final }
                return try generateRecursiveAny(nextGen, with: inputValue, context: &context)

        // MARK: pick

            case let .impure(operation: .pick(choices, totalWeight), continuation):
                guard let selectedChoice = WeightedPickSelection.draw(
                    from: choices, totalWeight: totalWeight, using: &context.prng
                ) else {
                    return nil
                }
                _ = context.prng.next()
                guard let value = try generateRecursiveAny(selectedChoice.generator, with: inputValue, context: &context) else {
                    return nil
                }
                let nextGen = try continuation(value)
                if case let .pure(final) = nextGen { return final }
                return try generateRecursiveAny(nextGen, with: inputValue, context: &context)

        // MARK: sequence

            case let .impure(operation: .sequence(lengthGen, elementGen), continuation):
                guard let lengthValue = try generateRecursiveAny(lengthGen.erase(), with: (), context: &context) else {
                    return nil
                }
                // The length spine is `UInt64`-typed by construction; a non-`UInt64` value is a malformed generator, not a recoverable condition.
                // swiftlint:disable:next force_cast
                let length = lengthValue as! UInt64
                let count = try SharedInterpreterHelpers.sequenceElementCount(length)
                var elements: [Any] = []
                elements.reserveCapacity(count)
                // Hoist scaling out of the per-element loop: size is stable within a run, so applyScaling (which includes pow() for exponential) produces the same effective range for every element.
                if case let .impure(
                    operation: .chooseBits(min, max, tag, _, .some(scaling), _),
                    continuation: elementContinuation
                ) = elementGen, context.sizeOverride == nil {
                    let size = consumeSize(&context)
                    let effectiveRange = Gen.applyScaling(
                        min: min, max: max, tag: tag, scaling: scaling, size: size
                    )

                    for _ in 0 ..< count {
                        let rawBits = context.prng.next(in: effectiveRange)
                        let randomBits: Any = tag.isFloatingPoint
                            ? tag.linearlyDistributed(rawBits: rawBits, in: effectiveRange)
                            : rawBits
                        let nextElementGen = try elementContinuation(randomBits)
                        if case let .pure(final) = nextElementGen {
                            elements.append(final)
                        } else {
                            guard let element = try generateRecursiveAny(
                                nextElementGen, with: inputValue, context: &context
                            ) else {
                                return nil
                            }
                            elements.append(element)
                        }
                    }
                } else {
                    for _ in 0 ..< count {
                        guard let element = try generateRecursiveAny(
                            elementGen, with: inputValue, context: &context
                        ) else {
                            return nil
                        }
                        elements.append(element)
                    }
                }
                let nextGen = try continuation(elements)
                if case let .pure(final) = nextGen { return final }
                return try generateRecursiveAny(nextGen, with: inputValue, context: &context)

        // MARK: zip

            case let .impure(operation: .zip(generators, _), continuation):
                var results = [Any]()
                results.reserveCapacity(generators.count)
                for childGen in generators {
                    guard let value = try generateRecursiveAny(
                        childGen, with: inputValue, context: &context
                    ) else {
                        throw GeneratorError.choiceTreeConstructionFailed
                    }
                    results.append(value)
                }
                let nextGen = try continuation(results)
                if case let .pure(final) = nextGen { return final }
                return try generateRecursiveAny(nextGen, with: inputValue, context: &context)

        // MARK: resize

            case let .impure(operation: .resize(newSize, innerGen), continuation):
                context.sizeOverride = newSize
                defer { context.sizeOverride = nil }
                guard let value = try generateRecursiveAny(innerGen, with: inputValue, context: &context) else {
                    return nil
                }
                let nextGen = try continuation(value)
                if case let .pure(final) = nextGen { return final }
                return try generateRecursiveAny(nextGen, with: inputValue, context: &context)

        // MARK: filter

            case let .impure(operation: .filter(filterGen, fingerprint, filterType, predicate, sourceLocation), continuation):
                let tunedGen = GenerationContext.resolveTunedFilter(
                    fingerprint: fingerprint,
                    generator: filterGen,
                    predicate: predicate,
                    type: filterType
                )
                var attempts = 0 as UInt64
                var accepted: Any?
                let observationDefault = FilterObservation(sourceLocation: sourceLocation, filterType: filterType)
                var filterAttempts = 0
                var filterPasses = 0
                var generatorYieldedNil = false
                while attempts < GenerationContext.maxFilterRuns {
                    guard let candidate = try generateRecursiveAny(
                        tunedGen, with: inputValue, context: &context
                    ) else {
                        generatorYieldedNil = true
                        break
                    }
                    let passed = predicate(candidate)
                    filterAttempts += 1
                    if passed { filterPasses += 1 }
                    if passed {
                        accepted = candidate
                        break
                    }
                    attempts += 1
                }
                if filterAttempts > 0 {
                    context.filterObservations[fingerprint, default: observationDefault]
                        .merge(FilterObservation(attempts: filterAttempts, passes: filterPasses))
                }
                if generatorYieldedNil { return nil }
                guard let value = accepted else {
                    sourceLocation.onBudgetExhausted?()
                    throw GeneratorError.sparseValidityCondition
                }
                let nextGen = try continuation(value)
                if case let .pure(final) = nextGen { return final }
                return try generateRecursiveAny(nextGen, with: inputValue, context: &context)

        // MARK: classify

            case let .impure(operation: .classify(classifyGen, fingerprint, classifiers), continuation):
                guard let value = try generateRecursiveAny(
                    classifyGen, with: inputValue, context: &context
                ) else {
                    return nil
                }
                for (label, classifier) in classifiers where classifier(value) {
                    context.classifications[fingerprint, default: [:]][label, default: []].insert(context.runs)
                }
                let nextGen = try continuation(value)
                if case let .pure(final) = nextGen { return final }
                return try generateRecursiveAny(nextGen, with: inputValue, context: &context)

        // MARK: transform

            case let .impure(operation: .transform(kind, inner), continuation):
                let transformedValue: Any
                switch kind {
                    case let .map(forward, _, _):
                        guard let innerValue = try generateRecursiveAny(
                            inner, with: inputValue, context: &context
                        ) else {
                            return nil
                        }
                        transformedValue = try forward(innerValue)
                    case let .bind(_, forward, _, _, _):
                        guard let innerValue = try generateRecursiveAny(
                            inner, with: inputValue, context: &context
                        ) else {
                            return nil
                        }
                        let boundGen = try forward(innerValue)
                        guard let boundValue = try generateRecursiveAny(
                            boundGen, with: inputValue, context: &context
                        ) else {
                            return nil
                        }
                        transformedValue = boundValue
                    case let .metamorphic(transforms, _):
                        let savedState = (context.prng.seed, context.prng.currentState)
                        guard let original = try generateRecursiveAny(
                            inner, with: inputValue, context: &context
                        ) else {
                            return nil
                        }
                        var copies: [Any] = [original]
                        copies.reserveCapacity(transforms.count + 1)
                        for transform in transforms {
                            context.prng = Xoshiro256(seed: savedState.0, state: savedState.1)
                            guard let copy = try generateRecursiveAny(
                                inner, with: inputValue, context: &context
                            ) else {
                                return nil
                            }
                            try copies.append(transform(copy))
                        }
                        transformedValue = copies
                }
                let nextGen = try continuation(transformedValue)
                if case let .pure(final) = nextGen { return final }
                return try generateRecursiveAny(nextGen, with: inputValue, context: &context)

        // MARK: unique

            case let .impure(operation: .unique(uniqueGen, fingerprint, keyExtractor), continuation):
                var attempts = 0 as UInt64
                var accepted: Any?
                while attempts < GenerationContext.maxFilterRuns {
                    if let keyExtractor {
                        guard let candidate = try generateRecursiveAny(
                            uniqueGen, with: inputValue, context: &context
                        ) else {
                            return nil
                        }
                        let key = keyExtractor(candidate)
                        if context.uniqueSeenKeys[fingerprint, default: []].insert(key).inserted {
                            accepted = candidate
                            break
                        }
                    } else {
                        var vactiContext = GenerationContext(
                            maxRuns: context.maxRuns,
                            baseSeed: context.baseSeed,
                            isFixed: context.isFixed,
                            size: context.size,
                            prng: Xoshiro256(seed: 0),
                            materializePicks: context.materializePicks,
                            runs: context.runs
                        )
                        swap(&context.prng, &vactiContext.prng)
                        let vactiResult = try ValueAndChoiceTreeInterpreter<Any>
                            .generateRecursiveAny(uniqueGen, with: inputValue, context: &vactiContext)
                        guard let (candidate, tree) = vactiResult else {
                            swap(&context.prng, &vactiContext.prng)
                            return nil
                        }
                        swap(&context.prng, &vactiContext.prng)
                        let sequence = ChoiceSequence.flatten(tree)
                        if context.uniqueSeenSequences[fingerprint, default: []].insert(sequence).inserted {
                            accepted = candidate
                            break
                        }
                    }
                    attempts += 1
                }
                guard let value = accepted else {
                    throw GeneratorError.uniqueBudgetExhausted
                }
                let nextGen = try continuation(value)
                if case let .pure(final) = nextGen { return final }
                return try generateRecursiveAny(nextGen, with: inputValue, context: &context)
        }
    }

    @inline(__always)
    static func consumeSize(_ context: inout GenerationContext) -> UInt64 {
        SharedInterpreterHelpers.consumeSize(&context)
    }
}
