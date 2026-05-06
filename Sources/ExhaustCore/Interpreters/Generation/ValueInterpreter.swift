//
//  ValueInterpreter.swift
//  Exhaust
//
//  Created by Chris Kolbu on 27/7/2025.
//


// MARK: - Academic Provenance

//
// Implements the `generate` interpretation G⟦·⟧ (Goldstein §3.3.3, Fig 4.3 for the reflective version). Pure forward pass that consumes PRNG entropy to produce values — no randomness capture.

package struct ValueInterpreter<Element>: ~Copyable, ExhaustIterator {
    let generator: ReflectiveGenerator<Element>
    private var context: GenerationContext

    /// Creates a value-only interpreter for the given generator with optional seed, run cap, and size override.
    public init(
        _ generator: ReflectiveGenerator<Element>,
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
        if !context.isFixed {
            context.prng = Xoshiro256.derive(from: context.baseSeed, at: context.runs)
        }

        defer { context.runs += 1 }
        do {
            return try Self.generateRecursive(generator, with: (), context: &context)
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

    /// Used to generate results around a similar level of complexity. Intended to be used to increase pool of results to compare against.
    func fixedAtSize() -> ValueInterpreter<Element> {
        var fixed = ValueInterpreter(
            generator,
            seed: context.baseSeed,
            maxRuns: context.maxRuns
        )
        fixed.context.isFixed = true
        fixed.context.runs = context.runs
        return fixed
    }

    // MARK: - Generator implementation

    static func generate<Output>(
        _ gen: ReflectiveGenerator<Output>,
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
        _ gen: ReflectiveGenerator<Output>,
        with inputValue: Any,
        context: inout GenerationContext
    ) throws -> Output? {
        // swiftlint:disable:next force_cast
        try generateRecursiveAny(gen.erase(), with: inputValue, context: &context) as! Output?
    }

    /// Non-generic recursive engine. One specialization in the binary regardless of Output type.
    static func generateRecursiveAny(
        _ gen: ReflectiveGenerator<Any>,
        with inputValue: Any,
        context: inout GenerationContext
    ) throws -> Any? {
        switch gen {
        case let .pure(value):
            return value

        case let .impure(operation, continuation):
            let result: Any?
            switch operation {
            case let .contramap(_, nextGen):
                result = try generateRecursiveAny(nextGen, with: inputValue, context: &context)

            case let .prune(nextGen):
                guard let wrappedValue = InterpreterWrapperHandlers.unwrapPruneInput(inputValue) else {
                    return nil
                }
                result = try generateRecursiveAny(nextGen, with: wrappedValue, context: &context)

            case let .pick(choices, _):
                guard let selectedChoice = WeightedPickSelection.draw(
                    from: choices, using: &context.prng
                ) else {
                    return nil
                }
                _ = context.prng.next()
                result = try generateRecursiveAny(selectedChoice.generator, with: inputValue, context: &context)

            case let .chooseBits(min, max, tag, _, scaling):
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
                result = randomBits

            case let .sequence(lengthGen, elementGen):
                guard let length = try generateRecursiveAny(
                    lengthGen.erase(), with: inputValue, context: &context
                ) as? UInt64 else {
                    return nil
                }
                var results: [Any] = []
                results.reserveCapacity(Int(length))
                for _ in 0 ..< length {
                    guard let element = try generateRecursiveAny(
                        elementGen, with: inputValue, context: &context
                    ) else {
                        return nil
                    }
                    results.append(element)
                }
                result = results

            case let .zip(generators, _):
                var results = [Any]()
                results.reserveCapacity(generators.count)
                for g in generators {
                    guard let r = try generateRecursiveAny(
                        g, with: inputValue, context: &context
                    ) else {
                        throw GeneratorError.couldNotGenerateConcomitantChoiceTree
                    }
                    results.append(r)
                }
                result = results

            case let .just(value):
                result = value

            case .getSize:
                let size = consumeSize(&context)
                result = size

            case let .resize(newSize, nextGen):
                context.sizeOverride = newSize
                result = try generateRecursiveAny(nextGen, with: inputValue, context: &context)

            case let .filter(gen, fingerprint, filterType, predicate, tuned, sourceLocation):
                let tunedGen: ReflectiveGenerator<Any>
                if let tuned {
                    tunedGen = tuned
                } else if filterType == .rejectionSampling {
                    tunedGen = gen
                } else if let cached = context.tunedFilterCache[fingerprint] {
                    tunedGen = cached
                } else {
                    let resolved = (try? ChoiceGradientTuner<Any>.tune(gen, predicate: predicate)) ?? gen
                    context.tunedFilterCache[fingerprint] = resolved
                    tunedGen = resolved
                }
                var attempts = 0 as UInt64
                var filterResult: Any?
                while attempts < GenerationContext.maxFilterRuns {
                    guard let candidate = try generateRecursiveAny(
                        tunedGen, with: inputValue, context: &context
                    ) else {
                        return nil
                    }
                    let passed = predicate(candidate)
                    if context.filterObservations[fingerprint] == nil {
                        context.filterObservations[fingerprint] = FilterObservation(sourceLocation: sourceLocation)
                    }
                    context.filterObservations[fingerprint]!.recordAttempt(passed: passed)
                    if passed {
                        filterResult = candidate
                        break
                    }
                    attempts += 1
                }
                guard let accepted = filterResult else {
                    throw GeneratorError.sparseValidityCondition
                }
                result = accepted

            case let .classify(gen, fingerprint, classifiers):
                guard let inner = try generateRecursiveAny(
                    gen, with: inputValue, context: &context
                ) else {
                    return nil
                }
                for (label, classifier) in classifiers where classifier(inner) {
                    if context.classifications[fingerprint] == nil {
                        context.classifications[fingerprint] = [:]
                    }
                    if context.classifications[fingerprint]![label] == nil {
                        context.classifications[fingerprint]![label] = []
                    }
                    context.classifications[fingerprint]![label]!.insert(context.runs)
                }
                result = inner

            case let .transform(kind, inner):
                switch kind {
                case let .map(forward, _, _):
                    guard let innerValue = try generateRecursiveAny(
                        inner, with: inputValue, context: &context
                    ) else {
                        return nil
                    }
                    result = try forward(innerValue)
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
                    result = boundValue
                case let .metamorphic(transforms, _):
                    let savedState = (context.prng.seed, context.prng.currentState)
                    guard let original = try generateRecursiveAny(
                        inner, with: inputValue, context: &context
                    ) else {
                        return nil
                    }
                    var results: [Any] = [original]
                    results.reserveCapacity(transforms.count + 1)
                    for transform in transforms {
                        context.prng = Xoshiro256(seed: savedState.0, state: savedState.1)
                        guard let copy = try generateRecursiveAny(
                            inner, with: inputValue, context: &context
                        ) else {
                            return nil
                        }
                        try results.append(transform(copy))
                    }
                    result = results
                }

            case let .unique(gen, fingerprint, keyExtractor):
                var attempts = 0 as UInt64
                var uniqueResult: Any?
                while attempts < GenerationContext.maxFilterRuns {
                    if let keyExtractor {
                        guard let candidate = try generateRecursiveAny(
                            gen, with: inputValue, context: &context
                        ) else {
                            return nil
                        }
                        let key = keyExtractor(candidate)
                        if context.uniqueSeenKeys[fingerprint, default: []].insert(key).inserted {
                            uniqueResult = candidate
                            break
                        }
                    } else {
                        var vactiContext = GenerationContext(
                            maxRuns: context.maxRuns,
                            baseSeed: context.baseSeed,
                            isFixed: context.isFixed,
                            size: context.size,
                            prng: Xoshiro256(seed: 0),
                            runs: context.runs
                        )
                        swap(&context.prng, &vactiContext.prng)
                        let vactiResult = try ValueAndChoiceTreeInterpreter<Any>
                            .generateRecursive(gen, with: inputValue, context: &vactiContext)
                        guard let (candidate, tree) = vactiResult else {
                            swap(&context.prng, &vactiContext.prng)
                            return nil
                        }
                        swap(&context.prng, &vactiContext.prng)
                        let sequence = ChoiceSequence.flatten(tree)
                        if context.uniqueSeenSequences[fingerprint, default: []].insert(sequence).inserted {
                            uniqueResult = candidate
                            break
                        }
                    }
                    attempts += 1
                }
                guard let accepted = uniqueResult else {
                    throw GeneratorError.uniqueBudgetExhausted
                }
                result = accepted
            }

            guard let value = result else { return nil }
            let nextGen = try continuation(value)
            if case let .pure(final) = nextGen { return final }
            return try generateRecursiveAny(nextGen, with: inputValue, context: &context)
        }
    }

    @inline(__always)
    private static func consumeSize(_ context: inout GenerationContext) -> UInt64 {
        if let override = context.sizeOverride {
            context.sizeOverride = nil
            return override
        }
        if context.size > 0 {
            return context.size
        }
        return GenerationContext.scaledSize(forRun: context.runs)
    }
}
