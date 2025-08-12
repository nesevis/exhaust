//
//  ValueAndChoiceTreeIterator.swift
//  Exhaust
//
//  Created by Chris Kolbu on 27/7/2025.
//

import Algorithms
import Foundation

public struct ValueAndChoiceTreeGenerator<FinalOutput>: IteratorProtocol, Sequence {
    // TODO: This will have to be inout?
    private struct Context {
        let maxRuns: UInt64
        let materializePicks: Bool
        var isFixed: Bool
        var size: UInt64
        var runs: UInt64
        var sizeOverride: UInt64? = nil
    }

    public typealias Element = (value: FinalOutput, tree: ChoiceTree)
    let generator: ReflectiveGenerator<FinalOutput>
    private(set) var prng: Xoshiro256
    private var context: Context
    
    public init(_ generator: ReflectiveGenerator<FinalOutput>, materializePicks: Bool = false, seed: UInt64? = nil, maxRuns: UInt64? = nil) {
        self.generator = generator
        self.prng = seed.map { Xoshiro256(seed: $0) } ?? Xoshiro256()
        self.context = .init(maxRuns: maxRuns ?? 100, materializePicks: materializePicks, isFixed: false, size: 0, runs: 0)
    }
    
    public mutating func next() -> Element? {
        guard context.runs < context.maxRuns else {
            return nil
        }
        defer {
            context.size += context.isFixed ? 0 : 1
            context.runs += 1
        }
        // Iterators can't have throwing `next` functions
        do {
            return try Self.generate(generator, context: context, using: &prng)
        } catch {
            let error = error
            fatalError(error.localizedDescription)
        }
    }

    /// Used to generate results around a similar level of complexity.
    /// Intended to be used to increase pool of results to compare against
    func fixedAtSize() -> ValueAndChoiceTreeGenerator<FinalOutput> {
        var fixed = ValueAndChoiceTreeGenerator(
            generator,
            materializePicks: context.materializePicks,
            seed: prng.seed,
            maxRuns: context.maxRuns
        )
        fixed.context.isFixed = true
        return fixed
    }
    
    // MARK: - Generator implementation
    
    private static func generate<Output>(
        _ gen: ReflectiveGenerator<Output>,
        context: Context,
        using rng: inout Xoshiro256
    ) throws -> (Output, ChoiceTree)? {
        // Delegate to the main generate function, providing the placeholder input.
        return try self.generate(gen, with: (), context: context, using: &rng)
    }

    private static func generate<Input, Output>(
        _ gen: ReflectiveGenerator<Output>,
        with input: Input,
        context: Context,
        using prng: inout Xoshiro256
    ) throws -> (Output, ChoiceTree)? {
        var sizeOverride: UInt64? = nil
        let result = try generateRecursive(
            gen,
            with: input,
            context: context,
            sizeOverride: &sizeOverride,
            prng: &prng
        )
        // TODO: Do we need to handle an error here?
        return result
    }

     // MARK: - Recursive Engine
    
    private static func generateRecursive<Input, Output>(
        _ gen: ReflectiveGenerator<Output>,
        with inputValue: Input,
        context: Context,
        sizeOverride: inout UInt64?,
        prng: inout Xoshiro256
    ) throws -> (Output, ChoiceTree)? {
        // Size override only affects the first call, not all subsequent ones
        switch gen {
        case let .pure(value):
            // The ChoiceTree value will be discarded from the caller if it's coming
            // from .chooseBits or .chooseCharacter
            return (value, ChoiceTree.just(String(String(describing: value).prefix(50))))
            
        case let .impure(operation, continuation):
            let jumpedRng = Xoshiro256(seed: prng.next())
            let continuationSizeOverride = sizeOverride
            
            let runContinuation = { (result: Any, calleeChoiceTree: ChoiceTree) -> (Output, ChoiceTree)? in
                // Do not move these down. It messes with optimisation and slows things down
                var sizeOverride = continuationSizeOverride
                var continuationRng = jumpedRng
                let nextGen = try continuation(result)
                
                // Optimisation! Do not remove. This early return cuts 70% of the time for string generators
                if calleeChoiceTree.isChoice, case let .pure(value) = nextGen {
                    // Early return for a pure case originating with a choice
                    return (value, calleeChoiceTree)
                }
                if let (continuationResult, innerChoiceTree) = try self.generateRecursive(
                    nextGen,
                    with: inputValue,
                    context: context,
                    sizeOverride: &sizeOverride,
                    prng: &continuationRng
                ) {
                    if nextGen.isPure {
                        return (continuationResult, calleeChoiceTree)
                    } else {
                        // A large part of the trace is adding these arrays together
                        // Use chain?
                        // FIXME: How do we discriminate between say a Gen.zip and a nested order?
                        // This is possible going backward, but going forward, the bind chain makes it difficult
                        // Can there be a ReflectiveOperation.zip([AnyGen])? This would make it very simple now that they're so type erased?
                        return (continuationResult, .group([calleeChoiceTree, innerChoiceTree]))
                    }
                }
                return nil
            }
            
            switch operation {
            case .lmap(_, let nextGen):
                // The lmap transform is not used in the forward pass
                // Run the nested generator and pass its result to the continuation
                guard let result = try self.generateRecursive(
                    nextGen,
                    with: inputValue,
                    context: context,
                    sizeOverride: &sizeOverride,
                    prng: &prng
                ) else { return nil }
                // At this stage we have the sequence result. But the continuation here
                let finalResult = try runContinuation(result.0, result.1)
                return finalResult

            case let .prune(nextGen):
                guard let optional = .some(inputValue as Optional<Any>), let wrappedValue = optional else {
                    return nil // Pruned!
                }
                guard let result = try self.generateRecursive(
                    nextGen,
                    with: wrappedValue,
                    context: context,
                    sizeOverride: &sizeOverride,
                    prng: &prng
                ) else { return nil }
                return try runContinuation(result.0, result.1)
                
            case let .pick(choices):
                let totalWeight = choices.reduce(0) { $0 + $1.weight }
                // This determines which of the branches will be selected
                var randomRoll = UInt64.random(in: 1...totalWeight, using: &prng)
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
                        if let result = try self.generateRecursive(
                            choice.generator,
                            with: inputValue,
                            context: context,
                            sizeOverride: &sizeOverride,
                            prng: &prng
                        ), let final = try runContinuation(result.0, result.1) {
                            value = final.0
                            branch = ChoiceTree.branch(label: choice.label, children: [final.1])
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
                
                guard
                    let value = finalValue
                else {
                    throw GeneratorError.couldNotGenerateConcomitantChoiceTree
                }
                
                return (value, .group(branches))

            case let .chooseBits(min, max, tag):
                // 1. Generate the raw, random bits. The interpreter's only job
                //    is to produce entropy within the specified bounds. It has
                //    no knowledge of the final `Output` type (e.g., Int, Float).
                let randomBits = UInt64.random(in: min...max, using: &prng)
                let choiceTree = ChoiceTree.choice(ChoiceValue(randomBits, tag: tag), .init(validRanges: [min...max]))
                
                // Run the continuation here, which is getting a .pure value, which we ignore
                // for ChoiceTree purposes
                if let (result, _) = try runContinuation(randomBits, choiceTree) {
                    return (result, choiceTree)
                }
                return nil

            case let .sequence(lengthGen, elementGen):
                
                // An iterative loop, not a recursive one. This will never overflow the stack.
                // This will return `getSize`
                guard let (length, lengthTrees) = try self.generateRecursive(
                    lengthGen,
                    with: inputValue, // TODO: Does this cause trouble?
                    context: context,
                    sizeOverride: &sizeOverride,
                    prng: &prng
                ) else {
                    return nil
                }
                
                var results: [Any] = []
                var elements: [ChoiceTree] = []
                results.reserveCapacity(Int(length))
                elements.reserveCapacity(Int(length) * 2) // Estimate for flattened elements
                
                for _ in 0..<length {
                    // Run the element generator once for each item.
                    // It's a self-contained generator, so its input is `()`.
                    guard let elementResult = try self.generateRecursive(
                        elementGen,
                        with: inputValue, // Does this lead to weirdness?
                        context: context,
                        sizeOverride: &sizeOverride,
                        prng: &prng
                    ) else {
                        // If any element fails to generate, the whole sequence fails.
                        return nil
                    }
                    results.append(elementResult.0)
                    elements.append(elementResult.1)
                    
                    // Inline the flatMap logic to avoid intermediate arrays
//                    let choiceTrees = elementResult.1
//                    if choiceTrees.count > 1 {
//                        elements.append(.group(choiceTrees))
//                    } else {
//                        elements.append(contentsOf: choiceTrees)
//                    }
                }
                
                let choiceTree = ChoiceTree.sequence(
                    length: length,
                    elements: elements,
                    lengthTrees.metadata // FIXME: This will now be a group
                )
                
                // Ignore the result ChoiceTree here; it will be a `just` value
                if let (result, _) = try runContinuation(results, choiceTree) {
                    return (result, choiceTree)
                }
                return nil
            case let .zip(generators):
                // This will reduce these generators into an array of results that the continuation will convert into a tuple
                var results = [Any]()
                results.reserveCapacity(generators.count)
                var choiceTrees = [ChoiceTree]()
                results.reserveCapacity(generators.count)
                for generator in generators {
                    guard let (result, tree) = try Self.generateRecursive(
                        generator,
                        with: inputValue,
                        context: context,
                        sizeOverride: &sizeOverride,
                        prng: &prng
                    ) else {
                        throw GeneratorError.couldNotGenerateConcomitantChoiceTree
                    }
                    results.append(result)
                    choiceTrees.append(tree)
                }
                return try runContinuation(results, .group(choiceTrees))
                
            case let .just(value):
                // FIXME: Not sure about this one
                // Ignore
                return try runContinuation(value, .just("\(value)"))
                
            case .getSize:
                let size = sizeOverride ?? logarithmicallyScaledSize(context.maxRuns, context.size)
                sizeOverride = nil // getSize consumes the `sizeOverride`
                return try runContinuation(size, .getSize(size))
                
            case let .resize(newSize, nextGen):
                sizeOverride = newSize
                guard let result = try self.generateRecursive(
                    nextGen,
                    with: inputValue,
                    context: context,
                    sizeOverride: &sizeOverride,
                    prng: &prng
                ) else { return nil }
                return try runContinuation(result, .resize(newSize: newSize, choices: [result.1]))
            }
        }
    }
    
    // MARK: - Quickcheck logarithmic scaling of test cases
    
    private static func logarithmicallyScaledSize(_ maxSize : UInt64, _ successfulTests : UInt64) -> UInt64 {
        let n = Double(successfulTests)
        return UInt64((log(n + 1)) * Double(maxSize) / log(100) / 2)
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
