//
//  ValueAndChoiceTreeIterator.swift
//  Exhaust
//
//  Created by Chris Kolbu on 27/7/2025.
//

import Foundation

// TODO: Rename
struct ValueAndChoiceTreeIterator<FinalOutput>: IteratorProtocol, Sequence {
    typealias Element = (value: FinalOutput, tree: ChoiceTree)?
    let generator: ReflectiveGenerator<Any, FinalOutput>
    private(set) var prng: Xoshiro256
    private var size: UInt64 = 0
    private var isFixed = false
    private(set) var maxRuns: UInt64
    
    init<Input>(_ generator: ReflectiveGenerator<Input, FinalOutput>, seed: UInt64? = nil, maxRuns: UInt64? = nil) {
        self.generator = generator
            .mapOperation(Gen.eraseInputType(from:))
        self.prng = seed.map { Xoshiro256(seed: $0) } ?? Xoshiro256()
        self.maxRuns = maxRuns ?? 100
    }
    
    mutating func next() -> Element? {
        guard size < maxRuns else {
            return nil
        }
        defer { size += isFixed ? 0 : 1 }
        // Iterators can't have throwing `next` functions
        do {
            return try Self.generate(generator, initialSize: size, maxRuns: maxRuns, using: &prng)
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
    
    static func generate<Output>(
        _ gen: ReflectiveGenerator<Any, Output>,
        initialSize: UInt64 = 0,
        maxRuns: UInt64,
        using rng: inout Xoshiro256
    ) throws -> (Output, ChoiceTree)? {
        // Delegate to the main generate function, providing the placeholder input.
        return try self.generate(gen, with: (), initialSize: initialSize, maxRuns: maxRuns, using: &rng)
    }
    
    static func generate<Output>(
        _ gen: ReflectiveGenerator<Void, Output>, // Constrained to Input == Void
        initialSize: UInt64 = 0,
        maxRuns: UInt64,
        using rng: inout Xoshiro256
    ) throws -> (Output, ChoiceTree)? {
        // Delegate to the main generate function, providing the placeholder input.
        return try self.generate(gen, with: (), initialSize: initialSize, maxRuns: maxRuns, using: &rng)
    }

    fileprivate static func generate<Input, Output>(
        _ gen: ReflectiveGenerator<Input, Output>,
        with input: Input,
        initialSize: UInt64 = 0,
        sizeOverride: UInt64? = nil,
        maxRuns: UInt64,
        using prng: inout Xoshiro256
    ) throws -> (Output, ChoiceTree)? {
        var sizeOverride: UInt64? = nil
        let startTime = Date()
        let result = try generateRecursive(
            gen,
            with: input,
            size: initialSize,
            maxRuns: maxRuns,
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
        _ gen: ReflectiveGenerator<Input, Output>,
        with inputValue: Input,
        size: UInt64,
        maxRuns: UInt64,
        sizeOverride: inout UInt64?,
        prng: inout Xoshiro256
    ) throws -> (Output, [ChoiceTree])? {
        // Size override only affects the first call, not all subsequent ones
        switch gen {
        case let .pure(value):
            // The ChoiceTree value will be discarded from the caller if it's coming
            // from .chooseBits or .chooseCharacter
            return (value, [ChoiceTree.just(String(String(describing: value).prefix(50)))])
            
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
                    size: size,
                    maxRuns: maxRuns,
                    sizeOverride: &sizeOverride,
                    prng: &continuationRng
                ) {
                    return (result, nextGen.isPure ? calleeChoiceTree : calleeChoiceTree + innerChoiceTree)
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
                    size: size,
                    maxRuns: maxRuns,
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
                    size: size,
                    maxRuns: maxRuns,
                    sizeOverride: &sizeOverride,
                    prng: &prng
                ) else { return nil }
                return try runContinuation(result.0, result.1)
                
            case let .pick(choices):
                // --- Production-Ready Weighted Choice ---
                guard !choices.isEmpty else { return nil }
                
                let totalWeight = choices.reduce(0) { $0 + $1.weight }
                guard totalWeight > 0 else {
                    // If all weights are 0, pick uniformly.
                    let randomIndex = Int.random(in: 0..<choices.count, using: &prng)
                    let chosen = choices[randomIndex]
                    guard let result = try self.generateRecursive(
                        chosen.generator,
                        with: inputValue,
                        size: size,
                        maxRuns: maxRuns,
                        sizeOverride: &sizeOverride,
                        prng: &prng
                    )
                    else {
                        return nil
                    }
                    
                    let wrapped = ChoiceTree.group([.branch(label: chosen.label, children: result.1)])
                    
                    // How can we materialise all the choices here?
                    return try runContinuation(result.0, [wrapped])
                }
                
                var randomRoll = UInt64.random(in: 1...totalWeight, using: &prng)
                
                for choice in choices {
                    if randomRoll <= choice.weight {
                        guard let result = try self.generateRecursive(
                            choice.generator,
                            with: inputValue,
                            size: size,
                            maxRuns: maxRuns,
                            sizeOverride: &sizeOverride,
                            prng: &prng
                        ) else { return nil }
                        let wrapped = ChoiceTree.group([.branch(label: choice.label, children: result.1)])
                        return try runContinuation(result.0, [wrapped])
                    }
                    randomRoll -= choice.weight
                }
                
                // Should be unreachable if totalWeight > 0
                return nil

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
                    size: size,
                    maxRuns: maxRuns,
                    sizeOverride: &sizeOverride,
                    prng: &prng
                ) else {
                    return nil
                }
                
                var results: [(Any, [ChoiceTree])?] = []
                results.reserveCapacity(Int(length))
                for _ in 0..<length {
                    // Run the element generator once for each item.
                    // It's a self-contained generator, so its input is `()`.
                    guard let element = try self.generateRecursive(
                        elementGen,
                        with: () as! Input,
                        size: size,
                        maxRuns: maxRuns,
                        sizeOverride: &sizeOverride,
                        prng: &prng
                    ) else {
                        // If any element fails to generate, the whole sequence fails.
                        return nil
                    }
                    results.append(element)
                }
                let choiceTree = ChoiceTree.sequence(
                    length: length,
                    elements: results.compactMap { $0?.1 }.flatMap { $0.count > 1 ? [.group($0)] : $0 },
                    lengthTrees.first(where: { $0.metadata.validRanges.isEmpty == false })!.metadata
                )
                
                // Ignore the result ChoiceTree here; it will be a `just` value
                let innerResult = [choiceTree]
                if let (result, _) = try runContinuation(results.compactMap { $0?.0 }, innerResult) {
                    return (result, innerResult)
                }
                return nil
            case let .just(value):
                // FIXME: Not sure about this one
                return try runContinuation(
                    value,
                    [.just(String(String(describing: value).prefix(50)))]
                )
                
            case .getSize:
                let size = sizeOverride ?? logarithmicallyScaledSize(maxRuns, size)
                sizeOverride = nil // getSize consumes the `sizeOverride`
                return try runContinuation(size, [.getSize(size)])
                
            case let .resize(newSize, nextGen):
                sizeOverride = newSize
                guard let result = try self.generateRecursive(
                    nextGen,
                    with: inputValue,
                    size: size,
                    maxRuns: maxRuns,
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
