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
                        guard let result = try generateRecursive(
                            nextGen, with: inputValue, rng: &rng, size: size
                        ) else { return nil }
                        return try runContinuation(
                            result, continuation,
                            inputValue: inputValue, rng: &rng, size: size
                        )

                    case let .prune(nextGen):
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

                    case let .pick(choices):
                        guard let selected = WeightedPickSelection.draw(from: choices, using: &rng) else {
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

                    case let .chooseBits(min, max, tag, _, scaling):
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

                    case let .sequence(lengthGen, elementGen):
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

                    case let .zip(generators, _):
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
                        guard let result = try generateRecursive(
                            nextGen, with: inputValue, rng: &rng, size: newSize
                        ) else {
                            return nil
                        }
                        return try runContinuation(
                            result, continuation,
                            inputValue: inputValue, rng: &rng, size: size
                        )

                    case let .filter(gen, _, _, predicate, tuned, sourceLocation):
                        let filterGen = tuned ?? gen
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

                    case let .classify(gen, _, _):
                        guard let result = try generateRecursive(
                            gen, with: inputValue, rng: &rng, size: size
                        ) else {
                            return nil
                        }
                        return try runContinuation(
                            result, continuation,
                            inputValue: inputValue, rng: &rng, size: size
                        )

                    case let .transform(kind, inner):
                        let result: Any
                        switch kind {
                            case let .map(forward, _, _):
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

                    case let .unique(gen, _, keyExtractor):
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
        }
    }

    // MARK: - Continuation

    @inline(__always)
    private static func runContinuation<Output>(
        _ result: Any,
        _ continuation: (Any) throws -> Generator<Output>,
        inputValue: some Any,
        rng: inout Xoshiro256,
        size: UInt64
    ) throws -> Output? {
        let nextGen = try continuation(result)
        return try generateRecursive(nextGen, with: inputValue, rng: &rng, size: size)
    }
}
