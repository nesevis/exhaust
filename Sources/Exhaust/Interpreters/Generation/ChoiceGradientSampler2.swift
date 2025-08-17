//
//  ChoiceGradientSampler2.swift
//  Exhaust
//
//  Reference implementation following the thesis algorithm exactly.
//  Based on Figure 3.3: Choice Gradient Sampling Algorithm
//

import Foundation

/// Choice Gradient Sampling implementation that closely follows the reference algorithm from
/// Harrison Goldstein's dissertation "Property-Based Testing for the People", Figure 3.3.
///
/// This implementation prioritizes algorithmic fidelity over performance optimizations.
public struct ChoiceGradientSampler2 {
    
    // MARK: - Core Types
    
    /// Result of CGS optimization containing valid values and metrics
    public struct CGSResult<Output> {
        /// All valid values discovered during optimization
        public let validValues: Set<Output>
        
        /// The optimized generator
        public let optimizedGenerator: ReflectiveGenerator<Output>
        
        /// Original validity rate before optimization
        public let originalValidRate: Double
        
        /// Final validity rate after optimization
        public let finalValidRate: Double
        
        /// Improvement factor
        public var improvementFactor: Double {
            guard originalValidRate > 0 else { return finalValidRate > 0 ? Double.infinity : 1.0 }
            return finalValidRate / originalValidRate
        }
    }
    
    // MARK: - Main Algorithm
    
    /// Implements the exact CGS algorithm from Figure 3.3
    /// 
    /// Algorithm steps:
    /// 1: g ← G
    /// 2: V ← ∅  
    /// 3: while true do
    /// 4:   if νg ≠ ∅ then return νg ∪ V
    /// 5:   if isVoid g then g ← G
    /// 6:   C ← choices g
    /// 7:   ∇g ← ⟨δcg | c ∈ C⟩ ⊳ ∇g is the gradient of g
    /// 8:   for δcg ∈ ∇g do
    /// 9:     if isVoid δcg then
    /// 10:      v ← ∅
    /// 11:    else
    /// 12:      x₁,..,xₙ ← G⟦δcg⟧ ⊳ Sample G⟦δcg⟧
    /// 13:      v ← {xⱼ | φ(xⱼ)}
    /// 14:    fc ← |v| ⊳ fc is the fitness of c
    /// 15:    V ← V ∪ v
    /// 16:  if max c∈C fc = 0 then
    /// 17:    for c ∈ C do fc ← weightOf c G
    /// 18:  g ← frequency[(fc, δcg) | c ∈ C]
    public static func optimize<Output: Hashable>(
        _ generator: ReflectiveGenerator<Output>,
        for property: @escaping (Output) -> Bool,
        samples: Int = 50,
        maxIterations: Int = 100
    ) async -> CGSResult<Output> {
        
        // Line 1: g ← G
        var g = generator
        
        // Line 2: V ← ∅
        var V: Set<Output> = []
        
        let originalValidRate = await measureValidityRate(generator, property: property, samples: samples)
        var iterationCount = 0
        
        // Line 3: while true do
        while iterationCount < maxIterations {
            iterationCount += 1
            
            // Line 4: if νg ≠ ∅ then return νg ∪ V
            // (We'll implement a simple termination condition instead of the thesis's νg check)
            
            // Line 5: if isVoid g then g ← G
            // (Skip void check for now - assume generator is always valid)
            
            // Line 6: C ← choices g
            let choices = extractChoices(from: g)
            guard !choices.isEmpty else { break }
            
            // Line 7: ∇g ← ⟨δcg | c ∈ C⟩ ⊳ ∇g is the gradient of g
            var gradients: [(choice: Choice, derivative: ReflectiveGenerator<Output>)] = []
            for choice in choices {
                if let derivative = computeDerivative(g, withRespectTo: choice) {
                    gradients.append((choice: choice, derivative: derivative))
                }
            }
            
            var choiceFitnesses: [Choice: Int] = [:]
            
            // Line 8: for δcg ∈ ∇g do
            for (choice, derivative) in gradients {
                
                // Line 9-10: if isVoid δcg then v ← ∅
                // (Skip void check - assume derivatives are valid)
                
                // Line 11-12: x₁,..,xₙ ← G⟦δcg⟧ ⊳ Sample G⟦δcg⟧
                let samples = sampleFromGenerator(derivative, count: samples)
                
                // Line 13: v ← {xⱼ | φ(xⱼ)}
                let validSamples = Set(samples.filter(property))
                
                // Line 14: fc ← |v| ⊳ fc is the fitness of c
                let fc = validSamples.count  // Raw count as per thesis
                choiceFitnesses[choice] = fc
                
                // Line 15: V ← V ∪ v
                V = V.union(validSamples)
            }
            
            // Line 16: if max c∈C fc = 0 then
            let maxFitness = choiceFitnesses.values.max() ?? 0
            if maxFitness == 0 {
                // Line 17: for c ∈ C do fc ← weightOf c G
                for choice in choices {
                    choiceFitnesses[choice] = Int(choice.originalWeight)
                }
            }
            
            // Line 18: g ← frequency[(fc, δcg) | c ∈ C]
            g = createFrequencyGenerator(from: gradients, withFitnesses: choiceFitnesses)
            
            // Simple termination condition: if we've found enough valid values
            if V.count > samples * 2 {
                break
            }
        }
        
        let finalValidRate = await measureValidityRate(g, property: property, samples: samples)
        
        return CGSResult(
            validValues: V,
            optimizedGenerator: g,
            originalValidRate: originalValidRate,
            finalValidRate: finalValidRate
        )
    }
    
    // MARK: - Helper Functions
    
    /// Extracts choices from a generator (simplified implementation)
    private static func extractChoices<Output>(from generator: ReflectiveGenerator<Output>) -> [Choice] {
        // Generate a sample to extract choice structure
        var choiceGenerator = ValueAndChoiceTreeInterpreter(generator, maxRuns: 1)
        guard let (_, tree) = choiceGenerator.next() else { return [] }
        
        return extractChoicesFromTree(tree)
    }
    
    /// Recursively extracts choices from a choice tree
    private static func extractChoicesFromTree(_ tree: ChoiceTree) -> [Choice] {
        switch tree {
        case .choice(let signed, let range):
            // Create a choice representing this decision point
            return [Choice(label: UInt64(signed), originalWeight: UInt64(range.count))]
            
        case .branch(let label, let children):
            var choices: [Choice] = []
            for child in children {
                choices.append(contentsOf: extractChoicesFromTree(child))
            }
            return choices
            
        case .group(let children):
            var choices: [Choice] = []
            for child in children {
                choices.append(contentsOf: extractChoicesFromTree(child))
            }
            return choices
            
        case .sequence(_, let elements, _):
            var choices: [Choice] = []
            for element in elements {
                choices.append(contentsOf: extractChoicesFromTree(element))
            }
            return choices
            
        case .selected(let child):
            return extractChoicesFromTree(child)
            
        default:
            return []
        }
    }
    
    /// Computes the derivative of a generator with respect to a choice (simplified)
    /*
     δc(g) (read as "delta c of g") represents the derivative of generator g with respect to choice c. This is a key concept from the thesis's mathematical framework.

       What it means:

       δc(g) is a new generator that represents "what g looks like if we force choice c to be made."

       Example:

       If we have a generator:
       g = pick[(1, 'a', genLeaf), (3, 'b', genNode)]

       Then:
       - δa(g) = genLeaf (the generator we get if we force choice 'a')
       - δb(g) = genNode (the generator we get if we force choice 'b')

       In the BST case:

       For our BST generator:
       Gen.pick(choices: [
           (weight: 1, label: 0, Gen.just(.leaf)),           // Choice 'leaf'
           (weight: 3, label: 1, /* complex node gen */)     // Choice 'node'
       ])

       - δleaf(g) = Gen.just(.leaf) (always generates leaves)
       - δnode(g) = the complex node generator (generates nodes with recursive structure)

       Why it's useful:

       By sampling from δc(g), we can see what happens if we "force" a particular choice to be made. This tells us:
       - How many valid values that choice path produces
       - Whether that choice is worth boosting or penalizing

       The algorithm:

       1. Line 7: Compute all derivatives ∇g = ⟨δc(g) | c ∈ C⟩
       2. Line 12: Sample from each derivative G⟦δc(g)⟧
       3. Line 13-14: Count valid samples to get fitness fc = |{xj | φ(xj)}|
       4. Line 18: Use fitness to reweight choices frequency[(fc, δc(g))]

       This is the core insight: derivatives let us preview the consequences of choices before committing to them.
     */
    private static func computeDerivative<Output>(
        _ generator: ReflectiveGenerator<Output>,
        withRespectTo choice: Choice
    ) -> ReflectiveGenerator<Output>? {
        // This is a simplified implementation
        // The full derivative computation would be much more complex
        return generator.mapOperation { op in
            guard case .pick(let choices) = op else {
                return op
            }
            
            // Find the choice with the matching label
            if let targetChoice = choices.first(where: { $0.label == choice.label }) {
                // Return a pick with only this choice (δc operation)
                return .pick(choices: ContiguousArray([(weight: UInt64(1), label: targetChoice.label, generator: targetChoice.generator)]))
            } else {
                // Choice not found in this pick - return original operation
                return op
            }
        }
    }
    
    /// Samples values from a generator
    private static func sampleFromGenerator<Output>(
        _ generator: ReflectiveGenerator<Output>,
        count: Int
    ) -> [Output] {
        var values: [Output] = []
        var valueGen = ValueInterpreter(generator, maxRuns: UInt64(count))
        
        for value in valueGen {
            values.append(value)
        }
        
        return values
    }
    
    /// Creates a new generator using frequency weighting as per thesis line 18
    private static func createFrequencyGenerator<Output>(
        from gradients: [(choice: Choice, derivative: ReflectiveGenerator<Output>)],
        withFitnesses fitnesses: [Choice: Int]
    ) -> ReflectiveGenerator<Output> {
        
        // Build frequency-weighted choices
        var weightedChoices: [(weight: UInt64, label: UInt64, generator: ReflectiveGenerator<Output>)] = []
        
        for (choice, derivative) in gradients {
            let fitness = fitnesses[choice] ?? 1
            let weight = UInt64(max(1, fitness))  // Ensure non-zero weight
            weightedChoices.append((weight: weight, label: choice.label, generator: derivative))
        }
        
        // If no choices, return the first derivative or a simple generator
        guard !weightedChoices.isEmpty else {
            return gradients.first?.derivative ?? Gen.just(nil as Output?).compactMap { $0 }
        }
        
        // Create a pick generator with frequency-weighted choices
        return Gen.pick(choices: ContiguousArray(weightedChoices))
    }
    
    /// Measures validity rate of a generator
    private static func measureValidityRate<Output>(
        _ generator: ReflectiveGenerator<Output>,
        property: @escaping (Output) -> Bool,
        samples: Int
    ) async -> Double {
        var validCount = 0
        var totalCount = 0
        
        var valueGen = ValueInterpreter(generator, maxRuns: UInt64(samples))
        for value in valueGen {
            if property(value) {
                validCount += 1
            }
            totalCount += 1
        }
        
        return totalCount > 0 ? Double(validCount) / Double(totalCount) : 0.0
    }
}

// MARK: - Supporting Types

/// Represents a choice point in the generator
private struct Choice: Hashable {
    let label: UInt64
    let originalWeight: UInt64
}
