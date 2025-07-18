//
//  Generator.swift
//  Exhaust
//
//  Created by Chris Kolbu on 15/7/2025.
//

import Foundation

enum Interpreters {
    final class GenerationContext {
        var size: UInt64
        var randomNumberGenerator: any RandomNumberGenerator
        
        init(size: UInt64, using rng: any RandomNumberGenerator) {
            self.size = size
            self.randomNumberGenerator = rng
        }
        
        /// Creates a copy of the context.
        func copy() -> GenerationContext {
            // Note: The PRNG is a class/reference type, so it's shared.
            // This is usually desired so the sequence of random numbers is not reset.
            return GenerationContext(size: self.size, using: self.randomNumberGenerator)
        }
    }
    
    public static func generate<Output>(
        _ gen: ReflectiveGenerator<Any, Output>,
        initialSize: UInt64 = 10,
        using rng: (any RandomNumberGenerator)? = nil
    ) -> Output? {
        // Delegate to the main generate function, providing the placeholder input.
        return self.generate(gen, with: (), initialSize: initialSize, using: rng)
    }
    
    public static func generate<Output>(
        _ gen: ReflectiveGenerator<Void, Output>, // Constrained to Input == Void
        initialSize: UInt64 = 10,
        using rng: (any RandomNumberGenerator)? = nil
    ) -> Output? {
        // Delegate to the main generate function, providing the placeholder input.
        return self.generate(gen, with: (), initialSize: initialSize, using: rng)
    }

    public static func generate<Input, Output>(
        _ gen: ReflectiveGenerator<Input, Output>,
        with input: Input,
        initialSize: UInt64 = 10,
        using rng: (any RandomNumberGenerator)? = nil
    ) -> Output? {
        // Use the provided PRNG or default to the system's.
        let initialRNG = rng ?? SystemRandomNumberGenerator()
        let context = GenerationContext(size: initialSize, using: initialRNG)
        
        let startTime = Date()
        let result = generateRecursive(gen, with: input, context: context)
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
        context: GenerationContext
    ) -> Output? {
        
        switch gen {
        case let .pure(value):
            return value
            
        case let .impure(operation, continuation):
            
            let runContinuation = { (result: Any) -> Output? in
                let nextGen = continuation(result)
                return self.generateRecursive(nextGen, with: inputValue, context: context)
            }
            
            switch operation {
            case .lmap(_, let nextGen):
                // The lmap transform is not used in the forward pass
                return runContinuation(nextGen)

            case let .prune(nextGen):
                guard let optional = .some(inputValue as Optional<Any>), let wrappedValue = optional else {
                    return nil // Pruned!
                }
                guard let result = self.generateRecursive(nextGen, with: wrappedValue, context: context) else { return nil }
                return runContinuation(result)
                
            case let .pick(choices):
                // --- Production-Ready Weighted Choice ---
                guard !choices.isEmpty else { return nil }
                
                let startTime = Date()
                let totalWeight = choices.reduce(0) { $0 + $1.weight }
                guard totalWeight > 0 else {
                    // If all weights are 0, pick uniformly.
                    let randomIndex = Int.random(in: 0..<choices.count, using: &context.randomNumberGenerator)
                    let chosenGenerator = choices[randomIndex].generator
                    guard let result = self.generateRecursive(chosenGenerator, with: inputValue, context: context) else { return nil }
                    
                    // Report pick event
                    if TycheReportContext.isReportingEnabled {
                        let duration = Date().timeIntervalSince(startTime)
                        let metadata = GenerationMetadata(
                            operationType: "pick-uniform",
                            generatorType: "Choice[\(choices.count)]",
                            size: context.size,
                            entropy: UInt64(randomIndex),
                            duration: duration
                        )
                        TycheReportContext.safeRecordGeneration(randomIndex, metadata: metadata)
                    }
                    
                    return runContinuation(result)
                }
                
                var randomRoll = UInt64.random(in: 1...totalWeight, using: &context.randomNumberGenerator)
                
                for (index, choice) in choices.enumerated() {
                    if randomRoll <= choice.weight {
                        guard let result = self.generateRecursive(choice.generator, with: inputValue, context: context) else { return nil }
                        
                        // Report weighted pick event
                        if TycheReportContext.isReportingEnabled {
                            let duration = Date().timeIntervalSince(startTime)
                            let metadata = GenerationMetadata(
                                operationType: "pick-weighted",
                                generatorType: "Choice[\(choices.count)]",
                                size: context.size,
                                entropy: UInt64(index),
                                duration: duration
                            )
                            TycheReportContext.safeRecordGeneration(index, metadata: metadata)
                        }
                        
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
                let randomBits = UInt64.random(in: min...max, using: &context.randomNumberGenerator)
                let duration = Date().timeIntervalSince(startTime)
                
                // Report fine-grained generation event if Tyche reporting is enabled
                if TycheReportContext.isReportingEnabled {
                    let metadata = GenerationMetadata(
                        operationType: "chooseBits",
                        generatorType: "UInt64",
                        size: context.size,
                        entropy: randomBits,
                        duration: duration
                    )
                    TycheReportContext.safeRecordGeneration(randomBits, metadata: metadata)
                }
                
                // 2. Pass the raw UInt64 bits to the continuation.
                //    The `continuation` for a `FreeFunctions.choose<T>()` call was
                //    constructed to specifically expect a `UInt64` and perform
                //    the `T(bitPattern:)` decoding itself before continuing the chain.
                return runContinuation(randomBits)
            
            case let .chooseCharacter(min, max):
                // Generate a random Unicode scalar value and create a Character
                let randomScalar = UInt64.random(in: min...max, using: &context.randomNumberGenerator)
                let unicodeScalar = Unicode.Scalar(UInt32(randomScalar))!
                let character = Character(unicodeScalar)
                
                return runContinuation(character)
            case let .sequence(lengthGen, elementGen):
                var results: [Any] = []
//                    results.reserveCapacity(count)
                
                // An iterative loop, not a recursive one. This will never overflow the stack.
                guard let length = self.generateRecursive(lengthGen, with: () as! Input, context: context) else {
                    return nil
                }
                for _ in 0..<length {
                    // Run the element generator once for each item.
                    // It's a self-contained generator, so its input is `()`.
                    guard let element = self.generateRecursive(elementGen, with: () as! Input, context: context) else {
                        // If any element fails to generate, the whole sequence fails.
                        return nil
                    }
                    results.append(element)
                }
                
                // Pass the completed array to the continuation.
                return runContinuation(results)
            case let .just(value):
                return runContinuation(value)
            }
        }
    }
}
