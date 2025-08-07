//
//  ValueAndChoiceTreeIterator.swift
//  Exhaust
//
//  Created by Chris Kolbu on 27/7/2025.
//

import Algorithms
import Foundation

// TODO: Rename
public struct ValueAndChoiceTreeIterator<FinalOutput>: IteratorProtocol, Sequence {
    // TODO: This will have to be inout?
    private struct Context {
        let maxRuns: UInt64
        let materializePicks: Bool
        let isFixed: Bool
        var size: UInt64
        var sizeOverride: UInt64? = nil
    }

    public typealias Element = (value: FinalOutput, tree: ChoiceTree)
    let generator: ReflectiveGenerator<FinalOutput>
    private(set) var prng: Xoshiro256
    private var context: Context
    
    public init(_ generator: ReflectiveGenerator<FinalOutput>, materializePicks: Bool = false, seed: UInt64? = nil, maxRuns: UInt64? = nil) {
        self.generator = generator
            .mapOperation(Gen.eraseInputType(from:))
        self.prng = seed.map { Xoshiro256(seed: $0) } ?? Xoshiro256()
        self.context = .init(maxRuns: maxRuns ?? 100, materializePicks: materializePicks, isFixed: false, size: 0)
    }
    
    public mutating func next() -> Element? {
        guard context.size < context.maxRuns else {
            return nil
        }
        defer { context.size += context.isFixed ? 0 : 1 }
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
//    func fixedAtSize() -> GeneratorIterator<Element> {
//        var fixed = GeneratorIterator(generator, seed: prng.seed, maxRuns: maxRuns)
//        fixed.isFixed = true
//        fixed.size = size
//        return fixed
//    }
    
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
        guard let (value, choiceTrees) = result else {
            throw GeneratorError.couldNotGenerateConcomitantChoiceTree
        }
        switch choiceTrees.count {
        case 0:
            throw GeneratorError.couldNotGenerateConcomitantChoiceTree
        case 1:
            return (value, choiceTrees[0])
        default:
            return (value, .group(choiceTrees))
        }
    }

     // MARK: - Recursive Engine
    
    private static func generateRecursive<Input, Output>(
        _ gen: ReflectiveGenerator<Output>,
        with inputValue: Input,
        context: Context,
        sizeOverride: inout UInt64?,
        ignoreChoiceTree: Bool = false,
        prng: inout Xoshiro256
    ) throws -> (Output, [ChoiceTree])? {
        // Size override only affects the first call, not all subsequent ones
        switch gen {
        case let .pure(value):
            // The ChoiceTree value will be discarded from the caller if it's coming
            // from .chooseBits or .chooseCharacter
            return (value, ignoreChoiceTree ? [] : [ChoiceTree.just(String(String(describing: value).prefix(50)))])
            
        case let .impure(operation, continuation):
            let jumpedRng = Xoshiro256(seed: prng.next())
            let continuationSizeOverride = sizeOverride
            // RunContinuation
            let runContinuation = { (result: Any, calleeChoiceTree: [ChoiceTree]) -> (Output, [ChoiceTree])? in
                // Will this work properly now?
                var sizeOverride = continuationSizeOverride
                let nextGen = try continuation(result)
                var continuationRng = jumpedRng
                if let (result, innerChoiceTree) = try self.generateRecursive(
                    nextGen,
                    with: inputValue,
                    context: context,
                    sizeOverride: &sizeOverride,
                    ignoreChoiceTree: calleeChoiceTree.contains(where: \.isChoice),
                    prng: &continuationRng
                ) {
                    if nextGen.isPure {
                        return (result, calleeChoiceTree)
                    } else {
                        // A large part of the trace is adding these arrays together
                        // Use chain?
                        return (result, calleeChoiceTree + innerChoiceTree)
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
                guard !choices.isEmpty else { return nil }
                
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
                
                var branches = [(Output, ChoiceTree)]()
                
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
                            branch = ChoiceTree.branch(label: choice.label, children: final.1)
                        }
                    }
                    
                    if let value, let branch {
                        if isSelected {
                            // Wrap in selected
                            branches.append((value, .selected(branch)))
                        } else {
                            branches.append((value, branch))
                        }
                    }
                }
                
                guard
                    let value = branches.first(where: { $0.1.isSelected })?.0
                else {
                    throw GeneratorError.couldNotGenerateConcomitantChoiceTree
                }
                let branchChoices = [ChoiceTree.group(branches.map(\.1))]
                
                return (value, branchChoices)

            case let .chooseBits(min, max):
                // 1. Generate the raw, random bits. The interpreter's only job
                //    is to produce entropy within the specified bounds. It has
                //    no knowledge of the final `Output` type (e.g., Int, Float).
                let randomBits = UInt64.random(in: min...max, using: &prng)
                let choiceTree = ChoiceTree.choice(ChoiceValue(randomBits), .init(validRanges: [min...max], strategies: []))
                
                // Run the continuation here, which is getting a .pure value, which we ignore
                // for ChoiceTree purposes
                if let (result, _) = try runContinuation(randomBits, [choiceTree]) {
                    return (result, [choiceTree])
                }
                return nil
            
            case let .chooseCharacter(min, max):
                // Generate a random Unicode scalar value and create a Character
                let randomScalar = UInt64.random(in: min...max, using: &prng)
                let unicodeScalar = Unicode.Scalar(UInt32(randomScalar)) ?? Unicode.Scalar(63)! // "?"
                let character = Character(unicodeScalar)
                let choiceTree = ChoiceTree.choice(ChoiceValue.character(character), .init(validRanges: [min...max], strategies: []))
                
                // Run the continuation here, which is getting a .pure value, which we ignore
                // for ChoiceTree purposes
                if let (result, _) = try runContinuation(character, [choiceTree]) {
                    return (result, [choiceTree])
                }
                return nil
            case let .sequence(lengthGen, elementGen):
                
                // An iterative loop, not a recursive one. This will never overflow the stack.
                // This will return `getSize`
                guard let (length, lengthTrees) = try self.generateRecursive(
                    lengthGen,
                    with: () as! Input,
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
                    guard let element = try self.generateRecursive(
                        elementGen,
                        with: () as! Input,
                        context: context,
                        sizeOverride: &sizeOverride,
                        prng: &prng
                    ) else {
                        // If any element fails to generate, the whole sequence fails.
                        return nil
                    }
                    results.append(element.0)
                    
                    // Inline the flatMap logic to avoid intermediate arrays
                    let choiceTrees = element.1
                    if choiceTrees.count > 1 {
                        elements.append(.group(choiceTrees))
                    } else {
                        elements.append(contentsOf: choiceTrees)
                    }
                }
                
                let choiceTree = ChoiceTree.sequence(
                    length: length,
                    elements: elements,
                    lengthTrees.first(where: { $0.metadata.validRanges.isEmpty == false })!.metadata
                )
                
                // Ignore the result ChoiceTree here; it will be a `just` value
                let innerResult = [choiceTree]
                if let (result, _) = try runContinuation(results, innerResult) {
                    return (result, innerResult)
                }
                return nil
            case let .just(value):
                // FIXME: Not sure about this one
                // Ignore
                return try runContinuation(
                    value,
                    [.just("<value>")]
                )
                
            case .getSize:
                let size = sizeOverride ?? logarithmicallyScaledSize(context.maxRuns, context.size)
                sizeOverride = nil // getSize consumes the `sizeOverride`
                return try runContinuation(size, [.getSize(size)])
                
            case let .resize(newSize, nextGen):
                sizeOverride = newSize
                guard let result = try self.generateRecursive(
                    nextGen,
                    with: inputValue,
                    context: context,
                    sizeOverride: &sizeOverride,
                    prng: &prng
                ) else { return nil }
                return try runContinuation(result, [.resize(newSize: newSize, choices: result.1)])
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
