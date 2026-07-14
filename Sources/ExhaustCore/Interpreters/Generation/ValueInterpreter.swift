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
            return try Self.generateRecursiveAny(erasedGenerator!, context: &context) as! Element?
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
        let result = try generateRecursive(gen, context: &context)
        swap(&rng, &context.prng)
        return result
    }

    // MARK: - Recursive Engine

    /// Typed entry point that erases the generator once at the boundary and casts the result.
    static func generateRecursive<Output>(
        _ gen: Generator<Output>,
        context: inout GenerationContext
    ) throws -> Output? {
        // swiftlint:disable:next force_cast
        try generateRecursiveAny(gen.erase(), context: &context) as! Output?
    }

    /// Non-generic recursive engine. One specialization in the binary regardless of Output type.
    ///
    /// The outer switch matches `.impure(.<operation>, continuation)` directly, enabling single-level dispatch without an intermediate operation variable.
    static func generateRecursiveAny(
        _ gen: AnyGenerator,
        context: inout GenerationContext
    ) throws -> Any? {
        switch gen {
            case let .pure(value):
                return value

            case let .impure(operation: .chooseBits(min, max, tag, _, scaling, _), continuation):
                return try handleChooseBits(
                    min: min, max: max, tag: tag, scaling: scaling,
                    continuation: continuation, context: &context
                )

            case let .impure(operation: .just(value), continuation):
                return try handleJust(value: value, continuation: continuation, context: &context)

            case .impure(operation: .getSize, let continuation):
                return try handleGetSize(continuation: continuation, context: &context)

            case let .impure(operation: .contramap(_, innerGen), continuation):
                return try handleContramap(innerGen: innerGen, continuation: continuation, context: &context)

            case let .impure(operation: .prune(innerGen), continuation):
                return try handlePrune(innerGen: innerGen, continuation: continuation, context: &context)

            case let .impure(operation: .pick(choices, totalWeight), continuation):
                return try handlePick(
                    choices: choices, totalWeight: totalWeight,
                    continuation: continuation, context: &context
                )

            case let .impure(operation: .sequence(lengthGen, elementGen), continuation):
                return try handleSequence(
                    lengthGen: lengthGen, elementGen: elementGen,
                    continuation: continuation, context: &context
                )

            case let .impure(operation: .zip(generators, _), continuation):
                return try handleZip(generators: generators, continuation: continuation, context: &context)

            case let .impure(operation: .resize(newSize, innerGen), continuation):
                return try handleResize(
                    newSize: newSize, innerGen: innerGen,
                    continuation: continuation, context: &context
                )

            case let .impure(operation: .filter(filterGen, fingerprint, filterType, predicate, sourceLocation), continuation):
                return try handleFilter(
                    filterGen: filterGen, fingerprint: fingerprint, filterType: filterType,
                    predicate: predicate, sourceLocation: sourceLocation,
                    continuation: continuation, context: &context
                )

            case let .impure(operation: .classify(classifyGen, fingerprint, classifiers), continuation):
                return try handleClassify(
                    classifyGen: classifyGen, fingerprint: fingerprint, classifiers: classifiers,
                    continuation: continuation, context: &context
                )

            case let .impure(operation: .transform(kind, inner), continuation):
                return try handleTransform(kind: kind, inner: inner, continuation: continuation, context: &context)

            case let .impure(operation: .unique(uniqueGen, fingerprint, keyExtractor), continuation):
                return try handleUnique(
                    uniqueGen: uniqueGen, fingerprint: fingerprint, keyExtractor: keyExtractor,
                    continuation: continuation, context: &context
                )
        }
    }

    // MARK: - Case Handlers

    //
    // Every `.impure` case body lives in an `@inline(__always)` handler rather than inline in the switch. `-Onone` neither honors `@inline(__always)` nor coalesces stack slots across mutually exclusive switch cases, so an inline switch gives the recursive dispatcher a frame carrying every case's locals at once (measured ~10 KB here), and debug builds overflow the stack on deeply nested generators. The constraint bites hardest on Linux and Windows, where ExhaustCore ships as source and always builds `-Onone` under `swift test`. Outlined, each recursion level pays the small dispatcher frame plus the one active handler's frame. `-O` mandatory inlining folds the handlers back into the monolithic switch, preserving the release codegen.

    @inline(__always)
    private static func handleChooseBits(
        min: UInt64,
        max: UInt64,
        tag: TypeTag,
        scaling: ChooseBitsScaling?,
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> Any? {
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
        return try generateRecursiveAny(nextGen, context: &context)
    }

    @inline(__always)
    private static func handleJust(
        value: Any,
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> Any? {
        let nextGen = try continuation(value)
        if case let .pure(final) = nextGen { return final }
        return try generateRecursiveAny(nextGen, context: &context)
    }

    @inline(__always)
    private static func handleGetSize(
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> Any? {
        let size = consumeSize(&context)
        let nextGen = try continuation(size)
        if case let .pure(final) = nextGen { return final }
        return try generateRecursiveAny(nextGen, context: &context)
    }

    @inline(__always)
    private static func handleContramap(
        innerGen: AnyGenerator,
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> Any? {
        guard let value = try generateRecursiveAny(innerGen, context: &context) else {
            return nil
        }
        let nextGen = try continuation(value)
        if case let .pure(final) = nextGen { return final }
        return try generateRecursiveAny(nextGen, context: &context)
    }

    @inline(__always)
    private static func handlePrune(
        innerGen: AnyGenerator,
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> Any? {
        // Forward generation never prunes (reflection-only), so the operation is a pass-through here.
        guard let value = try generateRecursiveAny(innerGen, context: &context) else {
            return nil
        }
        let nextGen = try continuation(value)
        if case let .pure(final) = nextGen { return final }
        return try generateRecursiveAny(nextGen, context: &context)
    }

    @inline(__always)
    private static func handlePick(
        choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        totalWeight: UInt64,
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> Any? {
        guard let selectedChoice = WeightedPickSelection.draw(
            from: choices, totalWeight: totalWeight, using: &context.prng
        ) else {
            return nil
        }
        _ = context.prng.next()
        guard let value = try generateRecursiveAny(selectedChoice.generator, context: &context) else {
            return nil
        }
        let nextGen = try continuation(value)
        if case let .pure(final) = nextGen { return final }
        return try generateRecursiveAny(nextGen, context: &context)
    }

    @inline(__always)
    private static func handleSequence(
        lengthGen: Generator<UInt64>,
        elementGen: AnyGenerator,
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> Any? {
        guard let lengthValue = try generateRecursiveAny(lengthGen.erase(), context: &context) else {
            return nil
        }
        // swiftlint:disable:next force_cast
        let length = lengthValue as! UInt64
        let count = try SharedInterpreterHelpers.sequenceElementCount(length)
        var elements: [Any] = []
        elements.reserveCapacity(count)
        // Unwrap a contramap layer before matching: forward generation ignores the backward transform, so contramap-wrapped elements (for example character generators) can take the fused loop below as long as the outer continuation is applied to each element.
        var fusedElementGen = elementGen
        var contramapContinuation: ((Any) throws -> AnyGenerator)?
        if case let .impure(operation: .contramap(_, innerGen), continuation: outerContinuation) = elementGen {
            fusedElementGen = innerGen
            contramapContinuation = outerContinuation
        }
        // Hoist scaling out of the per-element loop: size is stable within a run, so applyScaling (which includes pow() for exponential) produces the same effective range for every element. Unscaled elements take the same loop with their declared range.
        if case let .impure(
            operation: .chooseBits(min, max, tag, _, scaling, _),
            continuation: elementContinuation
        ) = fusedElementGen, scaling == nil || context.sizeOverride == nil {
            let effectiveRange: ClosedRange<UInt64>
            if let scaling {
                let size = consumeSize(&context)
                effectiveRange = Gen.applyScaling(
                    min: min, max: max, tag: tag, scaling: scaling, size: size
                )
            } else {
                effectiveRange = min ... max
            }

            for elementIndex in 0 ..< count {
                try SharedInterpreterHelpers.checkGenerationDeadline(context.deadlineNanoseconds, elementIndex: elementIndex)
                let rawBits = context.prng.next(in: effectiveRange)
                let randomBits: Any = tag.isFloatingPoint
                    ? tag.linearlyDistributed(rawBits: rawBits, in: effectiveRange)
                    : rawBits
                let nextElementGen = try elementContinuation(randomBits)
                var element: Any
                if case let .pure(final) = nextElementGen {
                    element = final
                } else {
                    guard let value = try generateRecursiveAny(
                        nextElementGen, context: &context
                    ) else {
                        return nil
                    }
                    element = value
                }
                if let contramapContinuation {
                    let outerGen = try contramapContinuation(element)
                    if case let .pure(final) = outerGen {
                        element = final
                    } else {
                        guard let value = try generateRecursiveAny(
                            outerGen, context: &context
                        ) else {
                            return nil
                        }
                        element = value
                    }
                }
                elements.append(element)
            }
        } else {
            for elementIndex in 0 ..< count {
                try SharedInterpreterHelpers.checkGenerationDeadline(context.deadlineNanoseconds, elementIndex: elementIndex)
                guard let element = try generateRecursiveAny(
                    elementGen, context: &context
                ) else {
                    return nil
                }
                elements.append(element)
            }
        }
        let nextGen = try continuation(elements)
        if case let .pure(final) = nextGen { return final }
        return try generateRecursiveAny(nextGen, context: &context)
    }

    @inline(__always)
    private static func handleZip(
        generators: ContiguousArray<AnyGenerator>,
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> Any? {
        var results = [Any]()
        results.reserveCapacity(generators.count)
        for childGen in generators {
            guard let value = try generateRecursiveAny(
                childGen, context: &context
            ) else {
                throw GeneratorError.choiceTreeConstructionFailed
            }
            results.append(value)
        }
        let nextGen = try continuation(results)
        if case let .pure(final) = nextGen { return final }
        return try generateRecursiveAny(nextGen, context: &context)
    }

    @inline(__always)
    private static func handleResize(
        newSize: UInt64,
        innerGen: AnyGenerator,
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> Any? {
        context.sizeOverride = newSize
        defer { context.sizeOverride = nil }
        guard let value = try generateRecursiveAny(innerGen, context: &context) else {
            return nil
        }
        let nextGen = try continuation(value)
        if case let .pure(final) = nextGen { return final }
        return try generateRecursiveAny(nextGen, context: &context)
    }

    @inline(__always)
    private static func handleFilter(
        filterGen: AnyGenerator,
        fingerprint: UInt64,
        filterType: FilterType,
        predicate: @escaping (Any) -> Bool,
        sourceLocation: FilterSourceLocation,
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> Any? {
        // Rejection-sampling filters never consult the tuned-filter cache, so they skip both the resolve call and the re-entrancy guard. For tuned filters, a fingerprint already being expanded higher on the path must not resolve: the cached chain contains this node and would recurse forever. The embedded inner is the correct local generator in both fallback cases (already tuned when the chain came from a tuning pass).
        let mustResolve = filterType != .rejectionSampling && context.filterExpansionPath.contains(fingerprint) == false
        if mustResolve {
            context.filterExpansionPath.append(fingerprint)
        }
        defer {
            if mustResolve {
                context.filterExpansionPath.removeLast()
            }
        }
        let tunedGen = mustResolve
            ? GenerationContext.resolveTunedFilter(
                fingerprint: fingerprint,
                generator: filterGen,
                predicate: predicate,
                type: filterType
            )
            : filterGen
        var attempts = 0 as UInt64
        let observationDefault = FilterObservation(sourceLocation: sourceLocation, filterType: filterType)
        var filterAttempts = 0
        var filterPasses = 0
        defer {
            if filterAttempts > 0 {
                context.filterObservations[fingerprint, default: observationDefault]
                    .merge(FilterObservation(attempts: filterAttempts, passes: filterPasses))
            }
        }
        while attempts < GenerationContext.maxFilterRuns {
            guard let candidate = try generateRecursiveAny(
                tunedGen, context: &context
            ) else { return nil }
            let passed = predicate(candidate)
            filterAttempts += 1
            if passed { filterPasses += 1 }
            if passed {
                let nextGen = try continuation(candidate)
                if case let .pure(final) = nextGen { return final }
                return try generateRecursiveAny(nextGen, context: &context)
            }
            attempts += 1
        }
        sourceLocation.onBudgetExhausted?()
        throw GeneratorError.sparseValidityCondition
    }

    @inline(__always)
    private static func handleClassify(
        classifyGen: AnyGenerator,
        fingerprint: UInt64,
        classifiers: [(label: String, predicate: (Any) -> Bool)],
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> Any? {
        guard let value = try generateRecursiveAny(
            classifyGen, context: &context
        ) else {
            return nil
        }
        for (label, classifier) in classifiers where classifier(value) {
            context.classifications[fingerprint, default: [:]][label, default: []].insert(context.runs)
        }
        let nextGen = try continuation(value)
        if case let .pure(final) = nextGen { return final }
        return try generateRecursiveAny(nextGen, context: &context)
    }

    @inline(__always)
    private static func handleTransform(
        kind: TransformKind,
        inner: AnyGenerator,
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> Any? {
        let transformedValue: Any
        switch kind {
            case let .map(forward, _, _, _), let .isomorph(forward, _, _, _):
                guard let innerValue = try generateRecursiveAny(
                    inner, context: &context
                ) else {
                    return nil
                }
                transformedValue = try forward(innerValue)
            case let .bind(_, forward, _, _, _):
                guard let innerValue = try generateRecursiveAny(
                    inner, context: &context
                ) else {
                    return nil
                }
                let boundGen = try forward(innerValue)
                guard let boundValue = try generateRecursiveAny(
                    boundGen, context: &context
                ) else {
                    return nil
                }
                transformedValue = boundValue
            case let .metamorphic(transforms, _):
                let savedState = (context.prng.seed, context.prng.currentState)
                let seenSnapshot = (context.uniqueSeenKeys, context.uniqueSeenSequences)
                guard let original = try generateRecursiveAny(
                    inner, context: &context
                ) else {
                    return nil
                }
                let seenAfterOriginal = (context.uniqueSeenKeys, context.uniqueSeenSequences)
                var copies: [Any] = [original]
                copies.reserveCapacity(transforms.count + 1)
                // Copies replay against the original's starting dedup state; see ReflectiveOperation.metamorphic.
                for transform in transforms {
                    context.prng = Xoshiro256(seed: savedState.0, state: savedState.1)
                    (context.uniqueSeenKeys, context.uniqueSeenSequences) = seenSnapshot
                    guard let copy = try generateRecursiveAny(
                        inner, context: &context
                    ) else {
                        return nil
                    }
                    try copies.append(transform(copy))
                }
                (context.uniqueSeenKeys, context.uniqueSeenSequences) = seenAfterOriginal
                transformedValue = copies
        }
        let nextGen = try continuation(transformedValue)
        if case let .pure(final) = nextGen { return final }
        return try generateRecursiveAny(nextGen, context: &context)
    }

    @inline(__always)
    private static func handleUnique(
        uniqueGen: AnyGenerator,
        fingerprint: UInt64,
        keyExtractor: ((Any) -> AnyHashable)?,
        continuation: (Any) throws -> AnyGenerator, context: inout GenerationContext
    ) throws -> Any? {
        var attempts = 0 as UInt64
        var accepted: Any?
        while attempts < GenerationContext.maxFilterRuns {
            if let keyExtractor {
                guard let candidate = try generateRecursiveAny(
                    uniqueGen, context: &context
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
                    .generateRecursiveAny(uniqueGen, context: &vactiContext)
                guard let (candidate, tree) = vactiResult else {
                    swap(&context.prng, &vactiContext.prng)
                    return nil
                }
                swap(&context.prng, &vactiContext.prng)
                let sequence = ChoiceSequence.flatten(tree)
                if context.uniqueSeenSequences[fingerprint, default: []].insert(sequence.operativeHash).inserted {
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
        return try generateRecursiveAny(nextGen, context: &context)
    }

    @inline(__always)
    static func consumeSize(_ context: inout GenerationContext) -> UInt64 {
        SharedInterpreterHelpers.consumeSize(&context)
    }
}
