//
//  GeneratorIterator.swift
//  Exhaust
//
//  Created by Chris Kolbu on 27/7/2025.
//

import Foundation

struct GeneratorIterator<Element>: IteratorProtocol, Sequence {
    let generator: ReflectiveGenerator<Any, Element>
    var prng: Xoshiro256
    var size: UInt64 = 0
    
    init(_ generator: ReflectiveGenerator<Any, Element>, seed: UInt64? = nil) {
        self.generator = generator
        self.prng = seed.map { Xoshiro256(seed: $0) } ?? Xoshiro256()
    }
    
    mutating func next() -> Element? {
        defer { size += 1 } 
        return Self.generate(generator, initialSize: size, using: &prng)
    }
    
    // MARK: - Generator implementation
    
    static func generate<Output>(
        _ gen: ReflectiveGenerator<Any, Output>,
        initialSize: UInt64 = 0,
        using rng: inout Xoshiro256
    ) -> Output? {
        // Delegate to the main generate function, providing the placeholder input.
        return self.generate(gen, with: (), initialSize: initialSize, using: &rng)
    }
    
    static func generate<Output>(
        _ gen: ReflectiveGenerator<Void, Output>, // Constrained to Input == Void
        initialSize: UInt64 = 0,
        using rng: inout Xoshiro256
    ) -> Output? {
        // Delegate to the main generate function, providing the placeholder input.
        return self.generate(gen, with: (), initialSize: initialSize, using: &rng)
    }

    fileprivate static func generate<Input, Output>(
        _ gen: ReflectiveGenerator<Input, Output>,
        with input: Input,
        initialSize: UInt64 = 0,
        sizeOverride: UInt64? = nil,
        using prng: inout Xoshiro256
    ) -> Output? {
        var sizeOverride: UInt64? = nil
        let startTime = Date()
        let result = generateRecursive(gen, with: input, size: initialSize, sizeOverride: &sizeOverride, prng: &prng)
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
        _ gen: ReflectiveGenerator<Input, Output>,
        with inputValue: Input,
        size: UInt64,
        sizeOverride: inout UInt64?,
        prng: inout Xoshiro256
    ) -> Output? {
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
                let nextGen = continuation(result)
                var continuationRng = jumpedRng
                return self.generateRecursive(nextGen, with: inputValue, size: size, sizeOverride: &sizeOverride, prng: &continuationRng)
            }
            
            switch operation {
            case .lmap(_, let nextGen):
                // The lmap transform is not used in the forward pass
                // Run the nested generator and pass its result to the continuation
                guard let result = self.generateRecursive(nextGen, with: inputValue, size: size, sizeOverride: &sizeOverride, prng: &prng) else { return nil }
                return runContinuation(result)

            case let .prune(nextGen):
                guard let optional = .some(inputValue as Optional<Any>), let wrappedValue = optional else {
                    return nil // Pruned!
                }
                guard let result = self.generateRecursive(nextGen, with: wrappedValue, size: size, sizeOverride: &sizeOverride, prng: &prng) else { return nil }
                return runContinuation(result)
                
            case let .pick(choices):
                // --- Production-Ready Weighted Choice ---
                guard !choices.isEmpty else { return nil }
                
                let startTime = Date()
                let totalWeight = choices.reduce(0) { $0 + $1.weight }
                guard totalWeight > 0 else {
                    // If all weights are 0, pick uniformly.
                    let randomIndex = Int.random(in: 0..<choices.count, using: &prng)
                    let chosenGenerator = choices[randomIndex].generator
                    guard let result = self.generateRecursive(chosenGenerator, with: inputValue, size: size, sizeOverride: &sizeOverride, prng: &prng) else { return nil }
                    
                    // Report pick event
//                    if TycheReportContext.isReportingEnabled {
//                        let duration = Date().timeIntervalSince(startTime)
//                        let metadata = GenerationMetadata(
//                            operationType: "pick-uniform",
//                            generatorType: "Choice[\(choices.count)]",
//                            size: &prng.size,
//                            entropy: UInt64(randomIndex),
//                            duration: duration
//                        )
//                        TycheReportContext.safeRecordGeneration(randomIndex, metadata: metadata)
//                    }
                    
                    return runContinuation(result)
                }
                
                var randomRoll = UInt64.random(in: 1...totalWeight, using: &prng)
                
                for (index, choice) in choices.enumerated() {
                    if randomRoll <= choice.weight {
                        guard let result = self.generateRecursive(choice.generator, with: inputValue, size: size, sizeOverride: &sizeOverride, prng: &prng) else { return nil }
                        
                        // Report weighted pick event
//                        if TycheReportContext.isReportingEnabled {
//                            let duration = Date().timeIntervalSince(startTime)
//                            let metadata = GenerationMetadata(
//                                operationType: "pick-weighted",
//                                generatorType: "Choice[\(choices.count)]",
//                                size: prng.size,
//                                entropy: UInt64(index),
//                                duration: duration
//                            )
//                            TycheReportContext.safeRecordGeneration(index, metadata: metadata)
//                        }
                        
                        return runContinuation(result)
                    }
                    randomRoll -= choice.weight
                }
                
                // Should be unreachable if totalWeight > 0
                return nil

            case let .chooseBits(min, max):
                // 1. Generate the raw, random bits. The interpreter's only job
                //    is to produce entropy within the specified bounds. It has
                //    no knowledge of the final `Output` type (e.g., Int, Float).
                let startTime = Date()
                let randomBits = UInt64.random(in: min...max, using: &prng)
                let duration = Date().timeIntervalSince(startTime)
                
                // Report fine-grained generation event if Tyche reporting is enabled
//                if TycheReportContext.isReportingEnabled {
//                    let metadata = GenerationMetadata(
//                        operationType: "chooseBits",
//                        generatorType: "\(Output.self)",
//                        size: prng.size,
//                        entropy: randomBits,
//                        duration: duration
//                    )
//                    TycheReportContext.safeRecordGeneration(randomBits, metadata: metadata)
//                }
                
                // 2. Pass the raw UInt64 bits to the continuation.
                //    The `continuation` for a `FreeFunctions.choose<T>()` call was
                //    constructed to specifically expect a `UInt64` and perform
                //    the `T(bitPattern:)` decoding itself before continuing the chain.
                return runContinuation(randomBits)
            
            case let .chooseCharacter(min, max):
                // Generate a random Unicode scalar value and create a Character
                let randomScalar = UInt64.random(in: min...max, using: &prng)
                let unicodeScalar = Unicode.Scalar(UInt32(randomScalar))!
                let character = Character(unicodeScalar)
                
                return runContinuation(character)
            case let .sequence(lengthGen, elementGen):
                
                // An iterative loop, not a recursive one. This will never overflow the stack.
                guard let length = self.generateRecursive(lengthGen, with: () as! Input, size: size, sizeOverride: &sizeOverride, prng: &prng) else {
                    return nil
                }
                var results: [Any] = []
                results.reserveCapacity(Int(length))
                for _ in 0..<length {
                    // Run the element generator once for each item.
                    // It's a self-contained generator, so its input is `()`.
                    guard let element = self.generateRecursive(elementGen, with: () as! Input, size: size, sizeOverride: &sizeOverride, prng: &prng) else {
                        // If any element fails to generate, the whole sequence fails.
                        return nil
                    }
                    results.append(element)
                }
                
                // Pass the completed array to the continuation.
                return runContinuation(results)
            case let .just(value):
                return runContinuation(value)
                
            case .getSize:
                let size = sizeOverride ?? logarithmicallyScaledSize(100, size)
                sizeOverride = nil // getSize consumes the `sizeOverride`
                return runContinuation(size)
                
            case let .resize(newSize, nextGen):
                sizeOverride = newSize
                guard let result = self.generateRecursive(nextGen, with: inputValue, size: size, sizeOverride: &sizeOverride, prng: &prng) else { return nil }
                return runContinuation(result)
            }
        }
    }
    
    // MARK: - Quickcheck logarithmic scaling of test cases
    
    private static func logarithmicallyScaledSize(_ maxSize : UInt64, _ successfulTests : UInt64) -> UInt64 {
        let n = Double(successfulTests)
        return UInt64((log(n + 1)) * Double(maxSize) / log(100))
    }
}
