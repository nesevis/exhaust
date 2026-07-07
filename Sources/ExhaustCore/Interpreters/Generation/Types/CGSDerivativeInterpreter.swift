//
//  CGSDerivativeInterpreter.swift
//  Exhaust
//
// MARK: - Why This Exists

//
// Minimal value-only evaluator for CGS derivative sampling. No ChoiceTree, no GenerationContext — just a PRNG and a size
// parameter. Replacing this with ValueInterpreter.generate causes a +28% regression (473ms → 606ms on the CGS
// filter-in-bind benchmark, 2026-05-12) because GenerationContext allocation/teardown and the erase-and-cast boundary
// dominate when thousands of derivative samples are taken per handlePick call.
//

/// Generates values without building a ``ChoiceTree`` or allocating a ``GenerationContext``.
///
/// Used by CGS derivative evaluation in ``OnlineCGSInterpreter/handlePick`` where only the output matters. The absence of ``GenerationContext`` eliminates per-sample allocation overhead that is load-bearing at the derivative sampling scale (thousands of samples per pick operation).
package enum CGSDerivativeInterpreter {
    /// Produces a single value from the generator using the provided PRNG, or returns `nil` if generation fails.
    @inline(__always)
    public static func sample<Output>(
        _ gen: Generator<Output>,
        using rng: inout Xoshiro256,
        size: UInt64 = 50
    ) throws -> Output? {
        try generateRecursive(gen, with: (), rng: &rng, size: size)
    }

    // MARK: - Recursive Engine

    private static func generateRecursive<Output>(
        _ gen: Generator<Output>,
        with inputValue: some Any,
        rng: inout Xoshiro256,
        size: UInt64
    ) throws -> Output? {
        switch gen {
            case let .pure(value):
                return value

            case let .impure(operation, continuation):
                switch operation {
                    case let .contramap(_, nextGen):
                        return try handleContramap(
                            nextGen: nextGen, continuation: continuation,
                            inputValue: inputValue, rng: &rng, size: size
                        )

                    case let .prune(nextGen):
                        return try handlePrune(
                            nextGen: nextGen, continuation: continuation,
                            inputValue: inputValue, rng: &rng, size: size
                        )

                    case let .pick(choices, totalWeight):
                        return try handlePick(
                            choices: choices, totalWeight: totalWeight, continuation: continuation,
                            inputValue: inputValue, rng: &rng, size: size
                        )

                    case let .chooseBits(min, max, tag, _, scaling, _):
                        return try handleChooseBits(
                            min: min, max: max, tag: tag, scaling: scaling, continuation: continuation,
                            inputValue: inputValue, rng: &rng, size: size
                        )

                    case let .sequence(lengthGen, elementGen):
                        return try handleSequence(
                            lengthGen: lengthGen, elementGen: elementGen, continuation: continuation,
                            inputValue: inputValue, rng: &rng, size: size
                        )

                    case let .zip(generators, _):
                        return try handleZip(
                            generators: generators, continuation: continuation,
                            inputValue: inputValue, rng: &rng, size: size
                        )

                    case let .just(value):
                        return try runContinuation(
                            value, continuation,
                            inputValue: inputValue, rng: &rng, size: size
                        )

                    case .getSize:
                        return try runContinuation(
                            size, continuation,
                            inputValue: inputValue, rng: &rng, size: size
                        )

                    case let .resize(newSize, nextGen):
                        return try handleResize(
                            newSize: newSize, nextGen: nextGen, continuation: continuation,
                            inputValue: inputValue, rng: &rng, size: size
                        )

                    case let .filter(gen, _, _, predicate, sourceLocation):
                        return try handleFilter(
                            gen: gen, predicate: predicate, sourceLocation: sourceLocation,
                            continuation: continuation,
                            inputValue: inputValue, rng: &rng, size: size
                        )

                    case let .classify(gen, _, _):
                        return try handleClassify(
                            gen: gen, continuation: continuation,
                            inputValue: inputValue, rng: &rng, size: size
                        )

                    case let .transform(kind, inner):
                        return try handleTransform(
                            kind: kind, inner: inner, continuation: continuation,
                            inputValue: inputValue, rng: &rng, size: size
                        )

                    case let .unique(gen, _, keyExtractor):
                        return try handleUnique(
                            gen: gen, keyExtractor: keyExtractor, continuation: continuation,
                            inputValue: inputValue, rng: &rng, size: size
                        )
                }
        }
    }

    // MARK: - Case Handlers

    //
    // Every non-trivial case body lives in an `@inline(__always)` handler rather than inline in the switch. See the Case Handlers note in ValueInterpreter for the debug stack-frame rationale; this interpreter runs thousands of derivative rollouts inside filter tuning, where the recursion depth compounds with nested filters.

    @inline(__always)
    private static func handleContramap<Output>(
        nextGen: AnyGenerator,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: some Any,
        rng: inout Xoshiro256,
        size: UInt64
    ) throws -> Output? {
        guard let result = try generateRecursive(
            nextGen, with: inputValue, rng: &rng, size: size
        ) else { return nil }
        return try runContinuation(
            result, continuation,
            inputValue: inputValue, rng: &rng, size: size
        )
    }

    @inline(__always)
    private static func handlePrune<Output>(
        nextGen: AnyGenerator,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: some Any,
        rng: inout Xoshiro256,
        size: UInt64
    ) throws -> Output? {
        guard let wrappedValue = InterpreterWrapperHandlers.unwrapPruneInput(
            inputValue
        ) else {
            return nil
        }
        guard let result = try generateRecursive(
            nextGen, with: wrappedValue, rng: &rng, size: size
        ) else { return nil }
        return try runContinuation(
            result, continuation,
            inputValue: inputValue, rng: &rng, size: size
        )
    }

    @inline(__always)
    private static func handlePick<Output>(
        choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        totalWeight: UInt64,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: some Any,
        rng: inout Xoshiro256,
        size: UInt64
    ) throws -> Output? {
        guard let selected = WeightedPickSelection.draw(from: choices, totalWeight: totalWeight, using: &rng) else {
            return nil
        }
        _ = rng.next() // parity with other interpreters
        guard let result = try generateRecursive(
            selected.generator, with: inputValue, rng: &rng, size: size
        ) else {
            return nil
        }
        return try runContinuation(
            result, continuation,
            inputValue: inputValue, rng: &rng, size: size
        )
    }

    @inline(__always)
    private static func handleChooseBits<Output>(
        min: UInt64,
        max: UInt64,
        tag: TypeTag,
        scaling: ChooseBitsScaling?,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: some Any,
        rng: inout Xoshiro256,
        size: UInt64
    ) throws -> Output? {
        let effective: ClosedRange<UInt64> = scaling.map {
            Gen.applyScaling(
                min: min, max: max, tag: tag, scaling: $0, size: size
            )
        } ?? (min ... max)
        let bits = rng.next(in: effective)
        return try runContinuation(
            bits, continuation,
            inputValue: inputValue, rng: &rng, size: size
        )
    }

    @inline(__always)
    private static func handleSequence<Output>(
        lengthGen: Generator<UInt64>,
        elementGen: AnyGenerator,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: some Any,
        rng: inout Xoshiro256,
        size: UInt64
    ) throws -> Output? {
        guard let length = try generateRecursive(
            lengthGen, with: inputValue, rng: &rng, size: size
        ) else {
            return nil
        }
        var results: [Any] = []
        results.reserveCapacity(Int(length))
        for _ in 0 ..< length {
            guard let element = try generateRecursive(
                elementGen, with: inputValue, rng: &rng, size: size
            ) else {
                return nil
            }
            results.append(element)
        }
        return try runContinuation(
            results, continuation,
            inputValue: inputValue, rng: &rng, size: size
        )
    }

    @inline(__always)
    private static func handleZip<Output>(
        generators: ContiguousArray<AnyGenerator>,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: some Any,
        rng: inout Xoshiro256,
        size: UInt64
    ) throws -> Output? {
        var results = [Any]()
        results.reserveCapacity(generators.count)
        for g in generators {
            guard let result = try generateRecursive(
                g, with: inputValue, rng: &rng, size: size
            ) else {
                return nil
            }
            results.append(result)
        }
        return try runContinuation(
            results, continuation,
            inputValue: inputValue, rng: &rng, size: size
        )
    }

    @inline(__always)
    private static func handleResize<Output>(
        newSize: UInt64,
        nextGen: AnyGenerator,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: some Any,
        rng: inout Xoshiro256,
        size: UInt64
    ) throws -> Output? {
        guard let result = try generateRecursive(
            nextGen, with: inputValue, rng: &rng, size: newSize
        ) else {
            return nil
        }
        return try runContinuation(
            result, continuation,
            inputValue: inputValue, rng: &rng, size: size
        )
    }

    @inline(__always)
    private static func handleFilter<Output>(
        gen: AnyGenerator,
        predicate: (Any) -> Bool,
        sourceLocation: FilterSourceLocation,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: some Any,
        rng: inout Xoshiro256,
        size: UInt64
    ) throws -> Output? {
        let filterGen = gen
        var attempts: UInt64 = 0
        while attempts < GenerationContext.maxFilterRuns {
            guard let result = try generateRecursive(
                filterGen, with: inputValue, rng: &rng, size: size
            ) else {
                return nil
            }
            if predicate(result) {
                return try runContinuation(
                    result, continuation,
                    inputValue: inputValue, rng: &rng, size: size
                )
            }
            attempts += 1
        }
        sourceLocation.onBudgetExhausted?()
        throw GeneratorError.sparseValidityCondition
    }

    @inline(__always)
    private static func handleClassify<Output>(
        gen: AnyGenerator,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: some Any,
        rng: inout Xoshiro256,
        size: UInt64
    ) throws -> Output? {
        guard let result = try generateRecursive(
            gen, with: inputValue, rng: &rng, size: size
        ) else {
            return nil
        }
        return try runContinuation(
            result, continuation,
            inputValue: inputValue, rng: &rng, size: size
        )
    }

    @inline(__always)
    private static func handleTransform<Output>(
        kind: TransformKind,
        inner: AnyGenerator,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: some Any,
        rng: inout Xoshiro256,
        size: UInt64
    ) throws -> Output? {
        let result: Any
        switch kind {
            case let .map(forward, _, _, _), let .isomorph(forward, _, _, _):
                guard let innerValue = try generateRecursive(
                    inner, with: inputValue, rng: &rng, size: size
                ) else {
                    return nil
                }
                result = try forward(innerValue)
            case let .bind(_, forward, _, _, _):
                guard let innerValue = try generateRecursive(
                    inner, with: inputValue, rng: &rng, size: size
                ) else {
                    return nil
                }
                let boundGen = try forward(innerValue)
                guard let boundValue = try generateRecursive(
                    boundGen, with: inputValue, rng: &rng, size: size
                ) else {
                    return nil
                }
                result = boundValue
            case let .metamorphic(transforms, _):
                let savedState = (rng.seed, rng.currentState)
                guard let original = try generateRecursive(
                    inner, with: inputValue, rng: &rng, size: size
                ) else {
                    return nil
                }
                var results: [Any] = [original]
                results.reserveCapacity(transforms.count + 1)
                for transform in transforms {
                    rng = Xoshiro256(seed: savedState.0, state: savedState.1)
                    guard let copy = try generateRecursive(
                        inner, with: inputValue, rng: &rng, size: size
                    ) else {
                        return nil
                    }
                    try results.append(transform(copy))
                }
                result = results
        }
        return try runContinuation(
            result, continuation,
            inputValue: inputValue, rng: &rng, size: size
        )
    }

    @inline(__always)
    private static func handleUnique<Output>(
        gen: AnyGenerator,
        keyExtractor: ((Any) -> AnyHashable)?,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: some Any,
        rng: inout Xoshiro256,
        size: UInt64
    ) throws -> Output? {
        // Skip dedup — this is just for fitness estimation
        guard let result = try generateRecursive(
            gen, with: inputValue, rng: &rng, size: size
        ) else {
            return nil
        }
        _ = keyExtractor // suppress unused warning
        return try runContinuation(
            result, continuation,
            inputValue: inputValue, rng: &rng, size: size
        )
    }

    // MARK: - Continuation

    @inline(__always)
    private static func runContinuation<Output>(
        _ result: Any,
        _ continuation: (Any) throws -> AnyGenerator,
        inputValue: some Any,
        rng: inout Xoshiro256,
        size: UInt64
    ) throws -> Output? {
        let nextGen = try continuation(result)
        return try generateRecursive(nextGen, with: inputValue, rng: &rng, size: size) as? Output
    }
}
