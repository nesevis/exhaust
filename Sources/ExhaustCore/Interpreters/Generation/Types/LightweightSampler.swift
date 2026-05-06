//
//  LightweightSampler.swift
//  Exhaust
//
//  Minimal value-only evaluator for CGS derivative sampling.
//  No ChoiceTree, no GenerationContext — just uniform generation.
//

package enum LightweightSampler {
    @inline(__always)
    public static func sample<Output>(
        _ gen: ReflectiveGenerator<Output>,
        using rng: inout Xoshiro256,
        size: UInt64 = 50
    ) throws -> Output? {
        try generateRecursive(gen, with: (), rng: &rng, size: size)
    }

    // MARK: - Recursive Engine

    private static func generateRecursive<Output>(
        _ gen: ReflectiveGenerator<Output>,
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

            case let .pick(choices, _):
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

            case let .filter(gen, _, _, predicate, tuned, _):
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
                // Lightweight: skip dedup entirely — this is just for fitness estimation
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
        _ continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        rng: inout Xoshiro256,
        size: UInt64
    ) throws -> Output? {
        let nextGen = try continuation(result)
        return try generateRecursive(nextGen, with: inputValue, rng: &rng, size: size)
    }
}
