//
//  ValueInterpreter.swift
//  Exhaust
//
//  Created by Chris Kolbu on 27/7/2025.
//

import Foundation

public struct ValueInterpreter<Element>: IteratorProtocol, Sequence {
    let generator: ReflectiveGenerator<Element>
    private(set) var prng: Xoshiro256
    private var size: UInt64 = 0
    private var isFixed = false
    private(set) var maxRuns: UInt64
    
    public init(_ generator: ReflectiveGenerator<Element>, seed: UInt64? = nil, maxRuns: UInt64? = nil) {
        self.generator = generator
        self.prng = seed.map { Xoshiro256(seed: $0) } ?? Xoshiro256()
        self.maxRuns = maxRuns ?? 100
    }
    
    public mutating func next() -> Element? {
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
    func fixedAtSize() -> ValueInterpreter<Element> {
        var fixed = ValueInterpreter(generator, seed: prng.seed, maxRuns: maxRuns)
        fixed.isFixed = true
        fixed.size = size
        return fixed
    }
    
    // MARK: - Generator implementation
    
    static func generate<Output>(
        _ gen: ReflectiveGenerator<Output>,
        initialSize: UInt64 = 0,
        maxRuns: UInt64,
        using rng: inout Xoshiro256
    ) throws -> Output? {
        // Delegate to the main generate function, providing the placeholder input.
        return try self.generate(gen, with: (), initialSize: initialSize, maxRuns: maxRuns, using: &rng)
    }

    fileprivate static func generate<Input, Output>(
        _ gen: ReflectiveGenerator<Output>,
        with input: Input,
        initialSize: UInt64 = 0,
        sizeOverride: UInt64? = nil,
        maxRuns: UInt64,
        using prng: inout Xoshiro256
    ) throws -> Output? {
        var sizeOverride: UInt64? = nil
        let startTime = Date()
        let result = try generateRecursive(gen, with: input, size: initialSize, maxRuns: maxRuns, sizeOverride: &sizeOverride, prng: &prng)
        let duration = Date().timeIntervalSince(startTime)
        
        // Report generation event if Tyche reporting is enabled
        if let result = result {
            let metadata = GenerationMetadata(
                operationType: "generate",
                generatorType: String(describing: type(of: gen)),
                size: initialSize,
                duration: duration
            )
            TycheReportContext.safeRecordGeneration(result, metadata: metadata)
        }
        
        return result
    }

     // MARK: - Recursive Engine
    
    private static func generateRecursive<Input, Output>(
        _ gen: ReflectiveGenerator<Output>,
        with inputValue: Input,
        size: UInt64,
        maxRuns: UInt64,
        sizeOverride: inout UInt64?,
        prng: inout Xoshiro256
    ) throws -> Output? {
        // Size override only affects the first call, not all subsequent ones
        switch gen {
        case let .pure(value):
            return value
            
        case let .impure(operation, continuation):
            let jumpedRng = Xoshiro256(seed: prng.next())
            let continuationSizeOverride = sizeOverride
            let runContinuation = { (result: Any) -> Output? in
                // Will this work properly now?
                var sizeOverride = continuationSizeOverride
                let nextGen = try continuation(result)
                // PERF: Potential early return here if this op is a terminal one (just, chooseBits, chooseCharacter) and the nextGen is pure
                var continuationRng = jumpedRng
                return try self.generateRecursive(nextGen, with: inputValue, size: size, maxRuns: maxRuns, sizeOverride: &sizeOverride, prng: &continuationRng)
            }
            
            switch operation {
            case .contramap(_, let nextGen):
                // The contramap transform is not used in the forward pass
                // Run the nested generator and pass its result to the continuation
                guard let result = try self.generateRecursive(nextGen, with: inputValue, size: size, maxRuns: maxRuns, sizeOverride: &sizeOverride, prng: &prng) else { return nil }
                return try runContinuation(result)

            case let .prune(nextGen):
                guard let optional = .some(inputValue as Optional<Any>), let wrappedValue = optional else {
                    return nil // Pruned!
                }
                guard let result = try self.generateRecursive(nextGen, with: wrappedValue, size: size, maxRuns: maxRuns, sizeOverride: &sizeOverride, prng: &prng) else { return nil }
                return try runContinuation(result)
                
            case let .pick(choices):
                guard !choices.isEmpty else { return nil }
                
                let totalWeight = choices.reduce(0) { $0 + $1.weight }
                guard totalWeight > 0 else {
                    let randomIndex = Int.random(in: 0..<choices.count, using: &prng)
                    let chosenGenerator = choices[randomIndex].generator
                    guard let result = try self.generateRecursive(chosenGenerator, with: inputValue, size: size, maxRuns: maxRuns, sizeOverride: &sizeOverride, prng: &prng) else { return nil }
                    
                    return try runContinuation(result)
                }
                
                var randomRoll = UInt64.random(in: 1...totalWeight, using: &prng)
                
                for choice in choices {
                    if randomRoll <= choice.weight {
                        guard let result = try self.generateRecursive(choice.generator, with: inputValue, size: size, maxRuns: maxRuns, sizeOverride: &sizeOverride, prng: &prng) else { return nil }
                        
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
                let randomBits = UInt64.random(in: min...max, using: &prng)
                
                // 2. Pass the raw UInt64 bits to the continuation.
                //    The `continuation` for a `FreeFunctions.choose<T>()` call was
                //    constructed to specifically expect a `UInt64` and perform
                //    the `T(bitPattern:)` decoding itself before continuing the chain.
                return try runContinuation(randomBits)

            case let .sequence(lengthGen, elementGen):
                
                // An iterative loop, not a recursive one. This will never overflow the stack.
                guard let length = try self.generateRecursive(lengthGen, with: () as! Input, size: size, maxRuns: maxRuns, sizeOverride: &sizeOverride, prng: &prng) else {
                    return nil
                }
                var results: [Any] = []
                results.reserveCapacity(Int(length))
                for _ in 0..<length {
                    // Run the element generator once for each item.
                    // It's a self-contained generator, so its input is `()`.
                    guard let element = try self.generateRecursive(elementGen, with: () as! Input, size: size, maxRuns: maxRuns, sizeOverride: &sizeOverride, prng: &prng) else {
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
                        size: size,
                        maxRuns: maxRuns,
                        sizeOverride: &sizeOverride,
                        prng: &prng
                    ) else {
                        throw GeneratorError.couldNotGenerateConcomitantChoiceTree
                    }
                    results.append(result)
                }
                return try runContinuation(results)
            case let .just(value):
                return try runContinuation(value)
                
            case .getSize:
                let size = sizeOverride ?? logarithmicallyScaledSize(maxRuns, size)
                sizeOverride = nil // getSize consumes the `sizeOverride`
                return try runContinuation(size)
                
            case let .resize(newSize, nextGen):
                sizeOverride = newSize
                guard let result = try self.generateRecursive(nextGen, with: inputValue, size: size, maxRuns: maxRuns, sizeOverride: &sizeOverride, prng: &prng) else { return nil }
                return try runContinuation(result)
            case let .filter(gen, _, _):
                guard let result = try self.generateRecursive(gen, with: inputValue, size: size, maxRuns: maxRuns, sizeOverride: &sizeOverride, prng: &prng) else { return nil }
                return try runContinuation(result)
            case let .classify(gen, fingerprint, classifiers):
                guard let result = try self.generateRecursive(gen, with: inputValue, size: size, maxRuns: maxRuns, sizeOverride: &sizeOverride, prng: &prng) else { return nil }

//                for (label, classifier) in classifiers where classifier(result) {
                    // TODO: we need to thread state here too
                    // Use the current run as the identifier for this value. We don't want to force `Equatable`
//                    context.classifications[fingerprint, default: [:]][label, default: []].insert(context.runs)
//                }
                
                return try runContinuation(result)
            }
        }
    }
    
    // MARK: - Quickcheck logarithmic scaling of test cases
    
    private static func logarithmicallyScaledSize(_ maxSize : UInt64, _ successfulTests : UInt64) -> UInt64 {
        let n = Double(successfulTests)
        
        return UInt64((log(n + 1)) * Double(maxSize) / log(100))
    }
}
