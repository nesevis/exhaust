//
//  ValueInterpreter.swift
//  Exhaust
//
//  Created by Chris Kolbu on 27/7/2025.
//

import Foundation

public struct ValueInterpreter<Element>: IteratorProtocol, Sequence {
    let generator: ReflectiveGenerator<Element>
    private var context: Context

    public init(_ generator: ReflectiveGenerator<Element>, seed: UInt64? = nil, maxRuns: UInt64? = nil) {
        self.generator = generator
        context = .init(
            maxRuns: maxRuns ?? 100,
            isFixed: false,
            size: 0,
            prng: seed.map { Xoshiro256(seed: $0) } ?? Xoshiro256(),
        )
    }

    public mutating func next() -> Element? {
        guard context.size < context.maxRuns else {
            return nil
        }
        defer { context.size += context.isFixed ? 0 : 1 }
        // Iterators can't have throwing `next` functions
        do {
            return try Self.generateRecursive(generator, with: (), context: context)
        } catch {
            let error = error
            fatalError(error.localizedDescription)
        }
    }

    /// Used to generate results around a similar level of complexity.
    /// Intended to be used to increase pool of results to compare against
    func fixedAtSize() -> ValueInterpreter<Element> {
        let fixed = ValueInterpreter(generator, seed: context.prng.seed, maxRuns: context.maxRuns)
        fixed.context.isFixed = true
        fixed.context.size = context.size
        return fixed
    }

    // MARK: - Generator implementation

    static func generate<Output>(
        _ gen: ReflectiveGenerator<Output>,
        initialSize: UInt64 = 0,
        maxRuns: UInt64,
        using rng: inout Xoshiro256,
    ) throws -> Output? {
        // Create a wrapper context that will be mutated during generation
        let context = Context(
            maxRuns: maxRuns,
            isFixed: false,
            size: initialSize,
            prng: rng,
        )
        let result = try generateRecursive(gen, with: (), context: context)
        // Copy the mutated PRNG state back to the caller's inout parameter
        rng = context.prng
        return result
    }

    // MARK: - Recursive Engine

    private static func generateRecursive<Input, Output>(
        _ gen: ReflectiveGenerator<Output>,
        with inputValue: Input,
        context: Context,
    ) throws -> Output? {
        // Size override only affects the first call, not all subsequent ones
        switch gen {
        case let .pure(value):
            return value

        case let .impure(operation, continuation):
            let runContinuation = { (result: Any) -> Output? in
                let nextGen = try continuation(result)
                // PERF: Potential early return here if this op is a terminal one (just, chooseBits, chooseCharacter) and the nextGen is pure
                return try generateRecursive(nextGen, with: inputValue, context: context)
            }

            switch operation {
            case let .contramap(_, nextGen):
                // The contramap transform is not used in the forward pass
                // Run the nested generator and pass its result to the continuation
                guard let result = try generateRecursive(nextGen, with: inputValue, context: context) else { return nil }
                return try runContinuation(result)

            case let .prune(nextGen):
                guard let optional = .some(inputValue as Any?), let wrappedValue = optional else {
                    return nil // Pruned!
                }
                guard let result = try generateRecursive(nextGen, with: wrappedValue, context: context) else { return nil }
                return try runContinuation(result)

            case let .pick(choices):
                let totalWeight = choices.reduce(0) { $0 + $1.weight }
                var randomRoll = UInt64.random(in: 1 ... totalWeight, using: &context.prng)
                // This will not be used, but we always have to consume it for parity with ValueAndChoiceTreeInterpreter's materializePicks
                _ = context.prng.next()

                for choice in choices {
                    if randomRoll <= choice.weight {
                        guard let result = try generateRecursive(choice.generator, with: inputValue, context: context) else { return nil }

                        return try runContinuation(result)
                    }
                    randomRoll -= choice.weight
                }

                // Should be unreachable if totalWeight > 0
                return nil

            case let .chooseBits(min, max, _):
                // 1. Generate the raw, random bits. The interpreter's only job
                //    is to produce entropy within the specified bounds. It has
                //    no knowledge of the final `Output` type (e.g., Int, Float).
                let randomBits = UInt64.random(in: min ... max, using: &context.prng)

                // 2. Pass the raw UInt64 bits to the continuation.
                //    The `continuation` for a `FreeFunctions.choose<T>()` call was
                //    constructed to specifically expect a `UInt64` and perform
                //    the `T(bitPattern:)` decoding itself before continuing the chain.
                return try runContinuation(randomBits)

            case let .sequence(lengthGen, elementGen):
                // An iterative loop, not a recursive one. This will never overflow the stack.
                guard let length = try generateRecursive(lengthGen, with: () as! Input, context: context) else {
                    return nil
                }
                var results: [Any] = []
                results.reserveCapacity(Int(length))
                for _ in 0 ..< length {
                    // Run the element generator once for each item.
                    // It's a self-contained generator, so its input is `()`.
                    guard let element = try generateRecursive(elementGen, with: () as! Input, context: context) else {
                        // If any element fails to generate, the whole sequence fails.
                        return nil
                    }
                    results.append(element)
                }

                // Pass the completed array to the continuation.
                return try runContinuation(results)

            case let .zip(generators):
                // This will reduce these generators into an array of results that the continuation will convert into a tuple
                var results = [Any]()
                results.reserveCapacity(generators.count)
                for generator in generators {
                    guard let result = try Self.generateRecursive(
                        generator,
                        with: inputValue,
                        context: context,
                    ) else {
                        throw GeneratorError.couldNotGenerateConcomitantChoiceTree
                    }
                    results.append(result)
                }
                return try runContinuation(results)

            case let .just(value):
                return try runContinuation(value)

            case .getSize:
                let size = context.sizeOverride ?? logarithmicallyScaledSize(context.maxRuns, context.size)
                context.sizeOverride = nil // getSize consumes the `sizeOverride`
                return try runContinuation(size)

            case let .resize(newSize, nextGen):
                context.sizeOverride = newSize
                guard let result = try generateRecursive(nextGen, with: inputValue, context: context) else { return nil }
                return try runContinuation(result)

            case let .filter(gen, _, _):
                guard let result = try generateRecursive(gen, with: inputValue, context: context) else { return nil }
                return try runContinuation(result)

            case let .classify(gen, _, _):
                guard let result = try generateRecursive(gen, with: inputValue, context: context) else { return nil }

//                for (label, classifier) in classifiers where classifier(result) {
//                    context.classifications[fingerprint, default: [:]][label, default: []].insert(context.runs)
//                }

                return try runContinuation(result)
            }
        }
    }

    // MARK: - Quickcheck logarithmic scaling of test cases

    private static func logarithmicallyScaledSize(_ maxSize: UInt64, _ successfulTests: UInt64) -> UInt64 {
        let n = Double(successfulTests)

        return UInt64(log(n + 1) * Double(maxSize) / log(100))
    }

    // MARK: - Hashable

    public func hash(into hasher: inout Hasher) {
        hasher.combine(context.prng.seed)
    }

    // MARK: - Context

    private final class Context {
        let maxRuns: UInt64
        var isFixed: Bool
        var size: UInt64
        var sizeOverride: UInt64?
        var prng: Xoshiro256

        init(
            maxRuns: UInt64,
            isFixed: Bool,
            size: UInt64,
            sizeOverride: UInt64? = nil,
            prng: Xoshiro256,
        ) {
            self.maxRuns = maxRuns
            self.isFixed = isFixed
            self.size = size
            self.sizeOverride = sizeOverride
            self.prng = prng
        }
    }
}
