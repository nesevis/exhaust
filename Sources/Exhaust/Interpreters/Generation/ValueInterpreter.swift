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

    private static func generateRecursive<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with inputValue: some Any,
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
                return try handleContramap(
                    nextGen,
                    inputValue: inputValue,
                    context: context,
                    runContinuation: runContinuation,
                )

            case let .prune(nextGen):
                return try handlePrune(
                    nextGen,
                    inputValue: inputValue,
                    context: context,
                    runContinuation: runContinuation,
                )

            case let .pick(choices):
                return try handlePick(
                    choices,
                    inputValue: inputValue,
                    context: context,
                    runContinuation: runContinuation,
                )

            case let .chooseBits(min, max, _, _):
                return try handleChooseBits(
                    min: min,
                    max: max,
                    context: context,
                    runContinuation: runContinuation,
                )

            case let .sequence(lengthGen, elementGen):
                return try handleSequence(
                    lengthGen: lengthGen,
                    elementGen: elementGen,
                    context: context,
                    runContinuation: runContinuation,
                )

            case let .zip(generators):
                return try handleZip(
                    generators,
                    inputValue: inputValue,
                    context: context,
                    runContinuation: runContinuation,
                )

            case let .just(value):
                return try runContinuation(value)

            case .getSize:
                let size = context.sizeOverride ?? logarithmicallyScaledSize(context.maxRuns, context.size)
                context.sizeOverride = nil // getSize consumes the `sizeOverride`
                return try runContinuation(size)

            case let .resize(newSize, nextGen):
                return try handleResize(
                    newSize: newSize,
                    nextGen: nextGen,
                    inputValue: inputValue,
                    context: context,
                    runContinuation: runContinuation,
                )

            case let .filter(gen, _, _):
                return try handlePassthrough(
                    gen,
                    inputValue: inputValue,
                    context: context,
                    runContinuation: runContinuation,
                )

            case let .classify(gen, _, _):
                return try handlePassthrough(
                    gen,
                    inputValue: inputValue,
                    context: context,
                    runContinuation: runContinuation,
                )
            }
        }
    }

    @inline(__always)
    private static func handleContramap<Output>(
        _ nextGen: ReflectiveGenerator<Any>,
        inputValue: some Any,
        context: Context,
        runContinuation: (Any) throws -> Output?,
    ) throws -> Output? {
        try InterpreterWrapperHandlers.continueAfterSubgenerator(
            runSubgenerator: { try generateRecursive(nextGen, with: inputValue, context: context) },
            runContinuation: runContinuation,
        )
    }

    @inline(__always)
    private static func handlePrune<Output>(
        _ nextGen: ReflectiveGenerator<Any>,
        inputValue: some Any,
        context: Context,
        runContinuation: (Any) throws -> Output?,
    ) throws -> Output? {
        guard let wrappedValue = InterpreterWrapperHandlers.unwrapPruneInput(inputValue) else {
            return nil
        }
        return try InterpreterWrapperHandlers.continueAfterSubgenerator(
            runSubgenerator: { try generateRecursive(nextGen, with: wrappedValue, context: context) },
            runContinuation: runContinuation,
        )
    }

    @inline(__always)
    private static func handlePick<Output>(
        _ choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        inputValue: some Any,
        context: Context,
        runContinuation: (Any) throws -> Output?,
    ) throws -> Output? {
        guard let selectedChoice = WeightedPickSelection.draw(from: choices, using: &context.prng) else {
            return nil
        }
        // Keep parity with ValueAndChoiceTreeInterpreter's materializePicks path.
        _ = context.prng.next()
        guard let result = try generateRecursive(selectedChoice.generator, with: inputValue, context: context) else {
            return nil
        }
        return try runContinuation(result)
    }

    @inline(__always)
    private static func handleChooseBits<Output>(
        min: UInt64,
        max: UInt64,
        context: Context,
        runContinuation: (Any) throws -> Output?,
    ) throws -> Output? {
        let randomBits = context.prng.next(in: min ... max)
        return try runContinuation(randomBits)
    }

    @inline(__always)
    private static func handleSequence<Output>(
        lengthGen: ReflectiveGenerator<UInt64>,
        elementGen: ReflectiveGenerator<Any>,
        context: Context,
        runContinuation: (Any) throws -> Output?,
    ) throws -> Output? {
        guard let length = try generateRecursive(lengthGen, with: (), context: context) else {
            return nil
        }
        var results: [Any] = []
        results.reserveCapacity(Int(length))
        let didSucceed = try SequenceExecutionKernel.run(count: length) {
            guard let element = try generateRecursive(elementGen, with: (), context: context) else {
                return false
            }
            results.append(element)
            return true
        }
        guard didSucceed else {
            return nil
        }
        return try runContinuation(results)
    }

    @inline(__always)
    private static func handleZip<Output>(
        _ generators: ContiguousArray<ReflectiveGenerator<Any>>,
        inputValue: some Any,
        context: Context,
        runContinuation: (Any) throws -> Output?,
    ) throws -> Output? {
        var results = [Any]()
        results.reserveCapacity(generators.count)
        for generator in generators {
            guard let result = try generateRecursive(generator, with: inputValue, context: context) else {
                throw GeneratorError.couldNotGenerateConcomitantChoiceTree
            }
            results.append(result)
        }
        return try runContinuation(results)
    }

    @inline(__always)
    private static func handleResize<Output>(
        newSize: UInt64,
        nextGen: ReflectiveGenerator<Any>,
        inputValue: some Any,
        context: Context,
        runContinuation: (Any) throws -> Output?,
    ) throws -> Output? {
        context.sizeOverride = newSize
        guard let result = try generateRecursive(nextGen, with: inputValue, context: context) else {
            return nil
        }
        return try runContinuation(result)
    }

    @inline(__always)
    private static func handlePassthrough<Output>(
        _ gen: ReflectiveGenerator<Any>,
        inputValue: some Any,
        context: Context,
        runContinuation: (Any) throws -> Output?,
    ) throws -> Output? {
        try InterpreterWrapperHandlers.continueAfterSubgenerator(
            runSubgenerator: { try generateRecursive(gen, with: inputValue, context: context) },
            runContinuation: runContinuation,
        )
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
