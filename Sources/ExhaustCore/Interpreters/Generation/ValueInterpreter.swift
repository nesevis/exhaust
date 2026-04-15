//
//  ValueInterpreter.swift
//  Exhaust
//
//  Created by Chris Kolbu on 27/7/2025.
//

import Foundation

// MARK: - Academic Provenance

//
// Implements the `generate` interpretation G⟦·⟧ (Goldstein §3.3.3, Fig 4.3 for the reflective version). Pure forward pass that consumes PRNG entropy to produce values — no randomness capture.

package struct ValueInterpreter<Element>: ~Copyable, ExhaustIterator {
    let generator: ReflectiveGenerator<Element>
    private var context: GenerationContext

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
            size: 0,
            prng: Xoshiro256(seed: baseSeed)
        )
        context.sizeOverride = sizeOverride
    }

    public mutating func next() throws -> Element? {
        guard context.runs < context.maxRuns else {
            return nil
        }

        // Per-run seed derivation: each run gets an independent PRNG
        if !context.isFixed {
            let runSeed = GenerationContext.runSeed(base: context.baseSeed, runIndex: context.runs)
            context.prng = Xoshiro256(seed: runSeed)
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

    private static func generateRecursive<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with inputValue: some Any,
        context: inout GenerationContext
    ) throws -> Output? {
        // Size override only affects the first call, not all subsequent ones
        switch gen {
        case let .pure(value):
            return value

        case let .impure(operation, continuation):
            let runContinuation = { (result: Any, context: inout GenerationContext) -> Output? in
                let nextGen = try continuation(result)
                if case let .pure(value) = nextGen {
                    return value
                }
                return try generateRecursive(nextGen, with: inputValue, context: &context)
            }

            switch operation {
            case let .contramap(_, nextGen):
                return try handleContramap(
                    nextGen,
                    inputValue: inputValue,
                    context: &context,
                    runContinuation: runContinuation
                )

            case let .prune(nextGen):
                return try handlePrune(
                    nextGen,
                    inputValue: inputValue,
                    context: &context,
                    runContinuation: runContinuation
                )

            case let .pick(choices):
                return try handlePick(
                    choices,
                    inputValue: inputValue,
                    context: &context,
                    runContinuation: runContinuation
                )

            case let .chooseBits(min, max, tag, _, scaling):
                return try handleChooseBits(
                    min: min,
                    max: max,
                    tag: tag,
                    scaling: scaling,
                    context: &context,
                    runContinuation: runContinuation
                )

            case let .sequence(lengthGen, elementGen):
                return try handleSequence(
                    lengthGen: lengthGen,
                    elementGen: elementGen,
                    context: &context,
                    runContinuation: runContinuation
                )

            case let .zip(generators, _):
                return try handleZip(
                    generators,
                    inputValue: inputValue,
                    context: &context,
                    runContinuation: runContinuation
                )

            case let .just(value):
                return try runContinuation(value, &context)

            case .getSize:
                let size = context.sizeOverride
                    ?? GenerationContext.scaledSize(forRun: context.runs)
                context.sizeOverride = nil // getSize consumes the `sizeOverride`
                return try runContinuation(size, &context)

            case let .resize(newSize, nextGen):
                return try handleResize(
                    newSize: newSize,
                    nextGen: nextGen,
                    inputValue: inputValue,
                    context: &context,
                    runContinuation: runContinuation
                )

            case let .filter(gen, fingerprint, filterType, predicate):
                let tunedGen = ChoiceTreeHandlers.resolveFilterGenerator(
                    gen: gen,
                    fingerprint: fingerprint,
                    filterType: filterType,
                    predicate: predicate,
                    context: &context
                )

                var attempts = 0 as UInt64
                while attempts < GenerationContext.maxFilterRuns {
                    guard let result = try generateRecursive(
                        tunedGen, with: inputValue, context: &context
                    ) else {
                        return nil
                    }

                    if predicate(result) {
                        return try runContinuation(result, &context)
                    }
                    attempts += 1
                }
                throw GeneratorError.sparseValidityCondition

            case let .classify(gen, _, _):
                return try handlePassthrough(
                    gen,
                    inputValue: inputValue,
                    context: &context,
                    runContinuation: runContinuation
                )

            case let .transform(kind, inner):
                return try handleTransform(
                    kind: kind,
                    inner: inner,
                    inputValue: inputValue,
                    context: &context,
                    runContinuation: runContinuation
                )

            case let .unique(gen, fingerprint, keyExtractor):
                var attempts = 0 as UInt64
                while attempts < GenerationContext.maxFilterRuns {
                    if let keyExtractor {
                        // Key-based: generate value directly and dedup by extracted key
                        guard let result = try generateRecursive(
                            gen, with: inputValue, context: &context
                        ) else {
                            return nil
                        }
                        let key = keyExtractor(result)
                        let isDuplicate = !context.uniqueSeenKeys[
                            fingerprint, default: []
                        ].insert(key).inserted
                        if !isDuplicate {
                            return try runContinuation(result, &context)
                        }
                    } else {
                        // Choice-sequence-based: need the tree to compute the sequence
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
                            .generateRecursive(
                                gen,
                                with: inputValue,
                                context: &vactiContext
                            )
                        guard let (result, tree) = vactiResult else {
                            swap(&context.prng, &vactiContext.prng)
                            return nil
                        }
                        swap(&context.prng, &vactiContext.prng)

                        let sequence = ChoiceSequence.flatten(tree)
                        let isDuplicate = !context.uniqueSeenSequences[
                            fingerprint, default: []
                        ].insert(sequence).inserted
                        if !isDuplicate {
                            return try runContinuation(result, &context)
                        }
                    }
                    attempts += 1
                }
                throw GeneratorError.uniqueBudgetExhausted
            }
        }
    }

    @inline(__always)
    private static func handleContramap<Output>(
        _ nextGen: ReflectiveGenerator<Any>,
        inputValue: some Any,
        context: inout GenerationContext,
        runContinuation: (Any, inout GenerationContext) throws -> Output?
    ) throws -> Output? {
        guard let result = try generateRecursive(
            nextGen, with: inputValue, context: &context
        ) else {
            return nil
        }
        return try runContinuation(result, &context)
    }

    @inline(__always)
    private static func handlePrune<Output>(
        _ nextGen: ReflectiveGenerator<Any>,
        inputValue: some Any,
        context: inout GenerationContext,
        runContinuation: (Any, inout GenerationContext) throws -> Output?
    ) throws -> Output? {
        guard let wrappedValue = InterpreterWrapperHandlers.unwrapPruneInput(inputValue) else {
            return nil
        }
        guard let result = try generateRecursive(
            nextGen, with: wrappedValue, context: &context
        ) else {
            return nil
        }
        return try runContinuation(result, &context)
    }

    @inline(__always)
    private static func handlePick<Output>(
        _ choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        inputValue: some Any,
        context: inout GenerationContext,
        runContinuation: (Any, inout GenerationContext) throws -> Output?
    ) throws -> Output? {
        guard let selectedChoice = WeightedPickSelection.draw(
            from: choices, using: &context.prng
        ) else {
            return nil
        }
        // Keep parity with ValueAndChoiceTreeInterpreter's materializePicks path.
        _ = context.prng.next()
        guard let result = try generateRecursive(
            selectedChoice.generator,
            with: inputValue,
            context: &context
        ) else {
            return nil
        }
        return try runContinuation(result, &context)
    }

    @inline(__always)
    private static func handleChooseBits<Output>(
        min: UInt64,
        max: UInt64,
        tag: TypeTag,
        scaling: ChooseBitsScaling?,
        context: inout GenerationContext,
        runContinuation: (Any, inout GenerationContext) throws -> Output?
    ) throws -> Output? {
        let effectiveRange: ClosedRange<UInt64>
        if let scaling {
            let size = consumeSize(&context)
            effectiveRange = Gen.applyScaling(
                min: min, max: max, tag: tag, scaling: scaling, size: size
            )
        } else {
            effectiveRange = min ... max
        }
        let randomBits = context.prng.next(in: effectiveRange)
        return try runContinuation(randomBits, &context)
    }

    /// Reads the active generation size: a one-shot `.resize` override if present, otherwise the per-run scaled size cycle.
    @inline(__always)
    private static func consumeSize(_ context: inout GenerationContext) -> UInt64 {
        if let override = context.sizeOverride {
            context.sizeOverride = nil
            return override
        }
        return GenerationContext.scaledSize(forRun: context.runs)
    }

    @inline(__always)
    private static func handleSequence<Output>(
        lengthGen: ReflectiveGenerator<UInt64>,
        elementGen: ReflectiveGenerator<Any>,
        context: inout GenerationContext,
        runContinuation: (Any, inout GenerationContext) throws -> Output?
    ) throws -> Output? {
        guard let length = try generateRecursive(lengthGen, with: (), context: &context) else {
            return nil
        }
        var results: [Any] = []
        results.reserveCapacity(Int(length))
        let didSucceed = try SequenceExecutionKernel.run(count: length) {
            guard let element = try generateRecursive(
                elementGen, with: (), context: &context
            ) else {
                return false
            }
            results.append(element)
            return true
        }
        guard didSucceed else {
            return nil
        }
        return try runContinuation(results, &context)
    }

    @inline(__always)
    private static func handleZip<Output>(
        _ generators: ContiguousArray<ReflectiveGenerator<Any>>,
        inputValue: some Any,
        context: inout GenerationContext,
        runContinuation: (Any, inout GenerationContext) throws -> Output?
    ) throws -> Output? {
        var results = [Any]()
        results.reserveCapacity(generators.count)
        for generator in generators {
            guard let result = try generateRecursive(
                generator, with: inputValue, context: &context
            ) else {
                throw GeneratorError.couldNotGenerateConcomitantChoiceTree
            }
            results.append(result)
        }
        return try runContinuation(results, &context)
    }

    @inline(__always)
    private static func handleResize<Output>(
        newSize: UInt64,
        nextGen: ReflectiveGenerator<Any>,
        inputValue: some Any,
        context: inout GenerationContext,
        runContinuation: (Any, inout GenerationContext) throws -> Output?
    ) throws -> Output? {
        context.sizeOverride = newSize
        guard let result = try generateRecursive(
            nextGen, with: inputValue, context: &context
        ) else {
            return nil
        }
        return try runContinuation(result, &context)
    }

    @inline(__always)
    private static func handleTransform<Output>(
        kind: TransformKind,
        inner: ReflectiveGenerator<Any>,
        inputValue: some Any,
        context: inout GenerationContext,
        runContinuation: (Any, inout GenerationContext) throws -> Output?
    ) throws -> Output? {
        let result: Any
        switch kind {
        case let .map(forward, _, _):
            guard let innerValue = try generateRecursive(
                inner, with: inputValue, context: &context
            ) else {
                return nil
            }
            result = try forward(innerValue)
        case let .bind(forward, _, _, _):
            guard let innerValue = try generateRecursive(
                inner, with: inputValue, context: &context
            ) else {
                return nil
            }
            let boundGen = try forward(innerValue)
            guard let boundValue = try generateRecursive(
                boundGen, with: inputValue, context: &context
            ) else {
                return nil
            }
            result = boundValue
        case let .metamorphic(transforms, _):
            let savedState = (context.prng.seed, context.prng.currentState)
            guard let original = try generateRecursive(
                inner, with: inputValue, context: &context
            ) else {
                return nil
            }
            var results: [Any] = [original]
            results.reserveCapacity(transforms.count + 1)
            for transform in transforms {
                context.prng = Xoshiro256(seed: savedState.0, state: savedState.1)
                guard let copy = try generateRecursive(
                    inner, with: inputValue, context: &context
                ) else {
                    return nil
                }
                try results.append(transform(copy))
            }
            result = results
        }
        return try runContinuation(result, &context)
    }

    @inline(__always)
    private static func handlePassthrough<Output>(
        _ gen: ReflectiveGenerator<Any>,
        inputValue: some Any,
        context: inout GenerationContext,
        runContinuation: (Any, inout GenerationContext) throws -> Output?
    ) throws -> Output? {
        guard let result = try generateRecursive(
            gen, with: inputValue, context: &context
        ) else {
            return nil
        }
        return try runContinuation(result, &context)
    }

}
