//
//  Generator.swift
//  Exhaust
//
//  Created by Chris Kolbu on 15/7/2025.
//

enum Interpreters {
    final class GenerationContext {
        var size: Int
        var randomNumberGenerator: any RandomNumberGenerator
        
        init(size: Int, using rng: any RandomNumberGenerator) {
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
        _ gen: ReflectiveGen<Void, Output>, // Constrained to Input == Void
        initialSize: Int = 10,
        using rng: (any RandomNumberGenerator)? = nil
    ) -> Output? {
        // Delegate to the main generate function, providing the placeholder input.
        return self.generate(gen, with: (), initialSize: initialSize, using: rng)
    }

    public static func generate<Input, Output>(
        _ gen: ReflectiveGen<Input, Output>,
        with input: Input,
        initialSize: Int = 10,
        using rng: (any RandomNumberGenerator)? = nil
    ) -> Output? {
        // Use the provided PRNG or default to the system's.
        let initialRNG = rng ?? SystemRandomNumberGenerator()
        let context = GenerationContext(size: initialSize, using: initialRNG)
        
        return generateRecursive(gen, with: input, context: context)
    }

    // MARK: - Recursive Engine
    
    private static func generateRecursive<Input, Output>(
        _ gen: ReflectiveGen<Input, Output>,
        with inputValue: Input,
        context: GenerationContext
    ) -> Output? {
        
        switch gen {
        case .pure(let value):
            return value
            
        case .impure(let operation, let continuation):
            
            let runContinuation = { (result: Any) -> Output? in
                let nextGen = continuation(result)
                return self.generateRecursive(nextGen, with: inputValue, context: context)
            }
            
            switch operation {
                
                //                case .from(let transform):
                //                    // Apply the transform. If it returns nil, the generation path fails.
                //                    guard let result = transform(inputValue) else { return nil }
                //                    return runContinuation(result)
                
            case .lmap(let transform, let nextGen):
                let nextInput = transform(inputValue)
                // The nested generator has its Input erased to `Any`, so this call is valid.
                guard let result = self.generateRecursive(nextGen, with: nextInput, context: context) else { return nil }
                return runContinuation(result)
                
            case .prune(let nextGen):
                guard let optional = .some(inputValue as Optional<Any>), let wrappedValue = optional else {
                    return nil // Pruned!
                }
                guard let result = self.generateRecursive(nextGen, with: wrappedValue, context: context) else { return nil }
                return runContinuation(result)
                
            case .pick(let choices):
                // --- Production-Ready Weighted Choice ---
                guard !choices.isEmpty else { return nil }
                
                let totalWeight = choices.reduce(0) { $0 + $1.weight }
                guard totalWeight > 0 else {
                    // If all weights are 0, pick uniformly.
                    let randomIndex = Int.random(in: 0..<choices.count, using: &context.randomNumberGenerator)
                    let chosenGenerator = choices[randomIndex].generator
                    guard let result = self.generateRecursive(chosenGenerator, with: inputValue, context: context) else { return nil }
                    return runContinuation(result)
                }
                
                var randomRoll = Int.random(in: 1...totalWeight, using: &context.randomNumberGenerator)
                
                for choice in choices {
                    if randomRoll <= choice.weight {
                        guard let result = self.generateRecursive(choice.generator, with: inputValue, context: context) else { return nil }
                        return runContinuation(result)
                    }
                    randomRoll -= choice.weight
                }
                
                // Should be unreachable if totalWeight > 0
                return nil
                
            case .getSize:
                return runContinuation(context.size)
                
            case .resize(let newSize, let nextGen):
                let resizedContext = context.copy()
                resizedContext.size = newSize
                guard let result = self.generateRecursive(nextGen, with: inputValue, context: resizedContext) else { return nil }
                return runContinuation(result)
                
            case .chooseBits(let min, let max):
                // 1. Generate the raw, random bits. The interpreter's only job
                //    is to produce entropy within the specified bounds. It has
                //    no knowledge of the final `Output` type (e.g., Int, Float).
                let randomBits = UInt64.random(in: min...max, using: &context.randomNumberGenerator)
                
                // 2. Pass the raw UInt64 bits to the continuation.
                //    The `continuation` for a `FreeFunctions.choose<T>()` call was
                //    constructed to specifically expect a `UInt64` and perform
                //    the `T(bitPattern:)` decoding itself before continuing the chain.
                return runContinuation(randomBits)
            case let .zip(a, b):
                guard
                    let resultA = generateRecursive(a, with: inputValue, context: context),
                    let resultB = generateRecursive(b, with: inputValue, context: context)
                else {
                    return nil
                }
                return runContinuation((resultA, resultB))
            }
        }
    }
}
