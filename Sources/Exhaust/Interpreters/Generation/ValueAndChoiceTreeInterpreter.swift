//
//  ValueAndChoiceTreeInterpreter.swift
//  Exhaust
//
//  Created by Chris Kolbu on 27/7/2025.
//

import Algorithms
import Foundation

public struct ValueAndChoiceTreeInterpreter<FinalOutput>: IteratorProtocol, Sequence {
    public typealias Element = (value: FinalOutput, tree: ChoiceTree)
    typealias RunContinuation<Output> = (Any, ChoiceTree) throws -> (Output, ChoiceTree)?
    typealias RunGenerator<Output> = (ReflectiveGenerator<Any>) throws -> (Output, ChoiceTree)?

    let generator: ReflectiveGenerator<FinalOutput>
    private var context: Context

    public init(
        _ generator: ReflectiveGenerator<FinalOutput>,
        materializePicks: Bool = false,
        seed: UInt64? = nil,
        maxRuns: UInt64? = nil,
    ) {
        self.generator = generator
        context = .init(
            maxRuns: maxRuns ?? 100,
            materializePicks: materializePicks,
            isFixed: false,
            size: 0,
            runs: 0,
            prng: seed.map { Xoshiro256(seed: $0) } ?? Xoshiro256(),
        )
    }

    // MARK: - Next

    public mutating func next() -> Element? {
        guard context.runs < context.maxRuns else {
            context.printClassifications()
            return nil
        }
        defer {
            context.size += context.isFixed ? 0 : 1
            context.runs += 1
        }
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
    func fixedAtSize() -> ValueAndChoiceTreeInterpreter<FinalOutput> {
        let fixed = ValueAndChoiceTreeInterpreter(
            generator,
            materializePicks: context.materializePicks,
            seed: context.prng.seed,
            maxRuns: context.maxRuns,
        )
        fixed.context.isFixed = true
        return fixed
    }

    // MARK: - Recursive Engine

    /// This code is all inline for performance reasons
    private static func generateRecursive<Output>(
        _ gen: ReflectiveGenerator<Output>,
        with inputValue: some Any,
        context: Context,
    ) throws -> (Output, ChoiceTree)? {
        // Size override only affects the first call, not all subsequent ones
        switch gen {
        case let .pure(value):
            // The ChoiceTree value will be discarded from the caller if it's coming
            // from .chooseBits or .chooseCharacter
            return (value, ChoiceTree.just(String(String(describing: value).prefix(50))))

        case let .impure(operation, continuation):
            // TODO: Extract the larger case-handlers into separate functions
            // Prebake the continuation and other parameters here for ease of calling
            let runContinuation: RunContinuation = { result, calleeChoiceTree in
                let nextGen = try continuation(result)

                // Optimisation! Do not remove. This early return cuts 70% of the time for string generators
                if calleeChoiceTree.isChoice, case let .pure(value) = nextGen {
                    // Early return for a pure case originating with a choice
                    return (value, calleeChoiceTree)
                }
                if let (continuationResult, innerChoiceTree) = try generateRecursive(
                    nextGen,
                    with: inputValue,
                    context: context,
                ) {
                    if nextGen.isPure {
                        return (continuationResult, calleeChoiceTree)
                    } else {
                        // A large part of the trace is adding these arrays together. Chain?
                        return (continuationResult, .group([calleeChoiceTree, innerChoiceTree]))
                    }
                }
                return nil
            }

            // Ditto for recursing a generator
            let runGenerator = { (gen: ReflectiveGenerator<Any>, context: Context) in
                try Self.generateRecursive(gen, with: inputValue, context: context)
            }

            switch operation {
                    // MARK: - Contramap

            case let .contramap(_, nextGen):
                // The contramap transform is not used in the forward pass
                // Run the nested generator and pass its result to the continuation
                guard let result = try runGenerator(nextGen, context) else { return nil }
                // At this stage we have the result.
                return try runContinuation(result.0, result.1)

                    // MARK: - Prune

            case let .prune(nextGen):
                guard let optional = .some(inputValue as Any?), let wrappedValue = optional else {
                    return nil // Pruned!
                }
                guard let result = try Self.generateRecursive(nextGen, with: wrappedValue, context: context) else { return nil }
                return try runContinuation(result.0, result.1)

                    // MARK: - Pick

            case let .pick(choices):
                let totalWeight = choices.reduce(0) { $0 + $1.weight }
                // This determines which of the branches will be selected
                var randomRoll = UInt64.random(in: 1 ... totalWeight, using: &context.prng)
                // This may or may not be used, but we always have to consume it
                let jumpSeed = context.prng.next()
                var selectedChoice: (weight: UInt64, label: UInt64, generator: ReflectiveGenerator<Any>)?
                for choice in choices {
                    if randomRoll <= choice.weight {
                        selectedChoice = choice
                        break
                    }
                    randomRoll -= choice.weight
                }

                var branches = [ChoiceTree]()
                branches.reserveCapacity(choices.count)
                var finalValue: Output?

                for choice in choices {
                    let isSelected = choice.label == selectedChoice?.label
                    var value: Output?
                    var branch: ChoiceTree?

                    if isSelected || context.materializePicks {
                        if let result = try runGenerator(choice.generator, isSelected ? context : context.jump(seed: jumpSeed)),
                           let final = try runContinuation(result.0, result.1)
                        {
                            value = final.0
                            branch = ChoiceTree.branch(weight: choice.weight, label: choice.label, choice: final.1)
                        }
                    }

                    if isSelected, let branch {
                        // Wrap in selected
                        finalValue = value
                        branches.append(.selected(branch))
                        if context.materializePicks == false {
                            // Do not iterate more
                            break
                        }
                    } else if let branch {
                        branches.append(branch)
                    }
                }

                guard let value = finalValue
                else {
                    throw GeneratorError.couldNotGenerateConcomitantChoiceTree
                }

                return (value, .group(branches))

                    // MARK: - Choosebits

            case let .chooseBits(min, max, tag):
                let randomBits = UInt64.random(in: min ... max, using: &context.prng)
                let choiceTree = ChoiceTree.choice(ChoiceValue(randomBits, tag: tag), .init(validRanges: [min ... max]))

                return try runContinuation(randomBits, choiceTree)

                    // MARK: - Sequence

            case let .sequence(lengthGen, elementGen):
                // An iterative loop, not a recursive one. This will never overflow the stack.
                guard let (length, lengthTrees) = try generateRecursive(
                    lengthGen,
                    with: inputValue,
                    context: context,
                ) else {
                    return nil
                }

                var results: [Any] = []
                var elements: [ChoiceTree] = []
                results.reserveCapacity(Int(length))
                elements.reserveCapacity(Int(length))

                for _ in 0 ..< length {
                    guard let (result, element) = try runGenerator(elementGen, context) else { return nil }
                    results.append(result)
                    elements.append(element)
                }

                let choiceTree = ChoiceTree.sequence(
                    length: length,
                    elements: elements,
                    lengthTrees.metadata, // FIXME: This will now be a group
                )

                // Ignore the result ChoiceTree here; it will be a `just` value
                if let (result, _) = try runContinuation(results, choiceTree) {
                    return (result, choiceTree)
                }
                return nil

                    // MARK: - Zip

            case let .zip(generators):
                // This will reduce these generators into an array of results that the continuation will convert into a tuple
                var results = [Any]()
                results.reserveCapacity(generators.count)
                var choiceTrees = [ChoiceTree]()
                results.reserveCapacity(generators.count)
                for gen in generators {
                    guard let (result, tree) = try runGenerator(gen, context) else {
                        throw GeneratorError.couldNotGenerateConcomitantChoiceTree
                    }
                    results.append(result)
                    choiceTrees.append(tree)
                }
                return try runContinuation(results, .group(choiceTrees))

                    // MARK: - Just

            case let .just(value):
                return try runContinuation(value, .just("\(value)"))

                    // MARK: - GetSize

            case .getSize:
                let size = context.sizeOverride ?? logarithmicallyScaledSize(context.maxRuns, context.runs)
                context.sizeOverride = nil // getSize consumes the `sizeOverride`
                return try runContinuation(size, .getSize(size))

                    // MARK: - Resize

            case let .resize(newSize, gen):
                context.sizeOverride = newSize // TODO: Investigate whether this has unintended consequences
                guard let result = try runGenerator(gen, context) else { return nil }
                return try runContinuation(result.0, .resize(newSize: newSize, choices: [result.1]))

                    // MARK: - Filter

            case let .filter(gen, _, predicate):
                // Optimise the `gen` with CGS here and execute it.
                // The predicate is by contract validating the output of `gen`
                // Q: How do we statefully preserve the CGS-optimised generator within this iterator?
                // A: Create an `inout [fingerprint: generator]` cache to thread through `generateRecursive`
                // Q: This fingerprint is created when the generator is specified, before it is run.
                // This means that if you Gen.zip(A, A, A), and A is a generator with a filter on it,
                // it will be generated once and cached for the run.
                // But what happens if the generator is statically declared as let gen = … and never changes?
                // …It would be CGS'ed once per iterator. Do we want a lock on a static cache, or keep it thread-local?
                // For now, let's use rejection sampling
                var attempts = 0 as UInt64
                while attempts < context.maxFilterRuns {
                    guard let (result, tree) = try runGenerator(gen, context) else { return nil }

                    if predicate(result) {
                        // print("Gen.filter found result after \(attempts) attempts")
                        return try runContinuation(result, tree)
                    }
                    attempts += 1
                }
                throw GeneratorError.sparseValidityCondition

                    // MARK: - Classify

            case let .classify(gen, fingerprint, classifiers):
                guard let result = try runGenerator(gen, context) else { return nil }

                for (label, classifier) in classifiers where classifier(result.0) {
                    // Use the current run as the identifier for this value. We don't want to force `Equatable`
                    context.classifications[fingerprint, default: [:]][label, default: []].insert(context.runs)
                }

                return try runContinuation(result.0, result.1)
            }
        }
    }

    // MARK: - Quickcheck logarithmic scaling of test cases

    private static func logarithmicallyScaledSize(_ maxSize: UInt64, _ successfulTests: UInt64) -> UInt64 {
        let n = Double(successfulTests)
        return UInt64(log(n + 1) * Double(maxSize) / log(100))
    }

    // MARK: - Context

    private final class Context {
        let maxRuns: UInt64
        let materializePicks: Bool
        var isFixed: Bool
        var size: UInt64
        var runs: UInt64
        var sizeOverride: UInt64?
        let maxFilterRuns: UInt64 = 500
        // A nested dictionary containing the results of classifying the results by provided predicates and labels
        var classifications: [UInt64: [String: Set<UInt64>]] = [:]
        var prng: Xoshiro256

        init(
            maxRuns: UInt64,
            materializePicks: Bool,
            isFixed: Bool,
            size: UInt64,
            runs: UInt64,
            sizeOverride: UInt64? = nil,
            classifications: [UInt64: [String: Set<UInt64>]] = [:],
            prng: Xoshiro256,
        ) {
            self.maxRuns = maxRuns
            self.materializePicks = materializePicks
            self.isFixed = isFixed
            self.size = size
            self.runs = runs
            self.sizeOverride = sizeOverride
            self.classifications = classifications
            self.prng = prng
        }

        func jump(seed: UInt64) -> Context {
            .init(maxRuns: maxRuns, materializePicks: materializePicks, isFixed: isFixed, size: size, runs: runs, prng: .init(seed: seed))
        }

        func printClassifications() {
            for (_, classifications) in classifications {
                print("Classifications for ??")
                for (label, runs) in classifications {
                    print("\(label):\t\(runs.count)")
                }
            }
        }
    }
}

private extension ReflectiveGenerator {
    var isPure: Bool {
        if case .pure = self {
            return true
        }
        return false
    }
}
