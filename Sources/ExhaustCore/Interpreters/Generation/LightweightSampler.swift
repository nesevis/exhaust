//
//  LightweightSampler.swift
//  Exhaust
//
//  Minimal value-only evaluator for CGS derivative sampling.
//  No ChoiceTree, no GenerationContext — just uniform generation.
//

enum LightweightSampler {
    @inline(__always)
    static func sample<Output>(
        _ gen: ReflectiveGenerator<Output>,
        using rng: inout Xoshiro256,
        size: UInt64 = 50,
    ) throws -> Output? {
        try eval(gen, with: (), rng: &rng, size: size)
    }

    // MARK: - Recursive Engine

    private static func eval<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with inputValue: some Any,
        rng: inout Xoshiro256,
        size: UInt64,
    ) throws -> Output? {
        switch gen {
        case let .pure(value):
            return value

        case let .impure(operation, continuation):
            switch operation {
            case let .contramap(_, nextGen):
                guard let result = try eval(nextGen, with: inputValue, rng: &rng, size: size) else { return nil }
                return try cont(result, continuation, inputValue: inputValue, rng: &rng, size: size)

            case let .prune(nextGen):
                guard let wrappedValue = InterpreterWrapperHandlers.unwrapPruneInput(inputValue) else {
                    return nil
                }
                guard let result = try eval(nextGen, with: wrappedValue, rng: &rng, size: size) else { return nil }
                return try cont(result, continuation, inputValue: inputValue, rng: &rng, size: size)

            case let .pick(choices):
                guard let selected = WeightedPickSelection.draw(from: choices, using: &rng) else {
                    return nil
                }
                _ = rng.next() // parity with other interpreters
                guard let result = try eval(selected.generator, with: inputValue, rng: &rng, size: size) else {
                    return nil
                }
                return try cont(result, continuation, inputValue: inputValue, rng: &rng, size: size)

            case let .chooseBits(min, max, _, _):
                let bits = rng.next(in: min ... max)
                return try cont(bits, continuation, inputValue: inputValue, rng: &rng, size: size)

            case let .sequence(lengthGen, elementGen):
                guard let length = try eval(lengthGen, with: inputValue, rng: &rng, size: size) else {
                    return nil
                }
                var results: [Any] = []
                results.reserveCapacity(Int(length))
                let ok = try SequenceExecutionKernel.run(count: length) {
                    guard let element = try eval(elementGen, with: inputValue, rng: &rng, size: size) else {
                        return false
                    }
                    results.append(element)
                    return true
                }
                guard ok else { return nil }
                return try cont(results, continuation, inputValue: inputValue, rng: &rng, size: size)

            case let .zip(generators):
                var results = [Any]()
                results.reserveCapacity(generators.count)
                for g in generators {
                    guard let result = try eval(g, with: inputValue, rng: &rng, size: size) else {
                        return nil
                    }
                    results.append(result)
                }
                return try cont(results, continuation, inputValue: inputValue, rng: &rng, size: size)

            case let .just(value):
                return try cont(value, continuation, inputValue: inputValue, rng: &rng, size: size)

            case .getSize:
                return try cont(size, continuation, inputValue: inputValue, rng: &rng, size: size)

            case let .resize(newSize, nextGen):
                guard let result = try eval(nextGen, with: inputValue, rng: &rng, size: newSize) else {
                    return nil
                }
                return try cont(result, continuation, inputValue: inputValue, rng: &rng, size: size)

            case let .filter(gen, _, _, predicate):
                var attempts: UInt64 = 0
                while attempts < 500 {
                    guard let result = try eval(gen, with: inputValue, rng: &rng, size: size) else { return nil }
                    if predicate(result) {
                        return try cont(result, continuation, inputValue: inputValue, rng: &rng, size: size)
                    }
                    attempts += 1
                }
                throw GeneratorError.sparseValidityCondition

            case let .classify(gen, _, _):
                guard let result = try eval(gen, with: inputValue, rng: &rng, size: size) else { return nil }
                return try cont(result, continuation, inputValue: inputValue, rng: &rng, size: size)

            case let .unique(gen, _, keyExtractor):
                // Lightweight: skip dedup entirely — this is just for fitness estimation
                guard let result = try eval(gen, with: inputValue, rng: &rng, size: size) else { return nil }
                _ = keyExtractor // suppress unused warning
                return try cont(result, continuation, inputValue: inputValue, rng: &rng, size: size)

            case let .recursive(base, extend):
                let unfolded = Gen.unfoldRecursive(base: base, extend: extend, size: size)
                guard let result = try eval(unfolded, with: inputValue, rng: &rng, size: size) else { return nil }
                return try cont(result, continuation, inputValue: inputValue, rng: &rng, size: size)
            }
        }
    }

    // MARK: - Continuation

    @inline(__always)
    private static func cont<Output>(
        _ result: Any,
        _ continuation: (Any) throws -> ReflectiveGenerator<Output>,
        inputValue: some Any,
        rng: inout Xoshiro256,
        size: UInt64,
    ) throws -> Output? {
        let nextGen = try continuation(result)
        return try eval(nextGen, with: inputValue, rng: &rng, size: size)
    }
}
