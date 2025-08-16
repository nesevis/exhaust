//
//  CGSPerformanceBenchmarks.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/8/2025.
//

import Testing
@testable import Exhaust

struct CGSPerformanceBenchmarks {
    
    @Test("CGS transformation analysis")
    func testCGSTransformationAnalysis() async throws {
        // Test different generator patterns to understand transformation effectiveness
        
        print("=== CGS Transformation Analysis ===")
        
        // Test 1: Simple choice generator (should show limited benefit)
        let simpleGen = Gen.choose(in: 0...100)
        let evenProperty: (Int) -> Bool = { $0 % 2 == 0 }
        
        let simpleResults = await ChoiceGradientSampler.optimize(
            simpleGen,
            for: evenProperty,
            samples: 200,
            iterations: 3
        )
        
        print("\n--- Simple Generator (Gen.choose) ---")
        print("Original: \(simpleResults.tuningMetrics.originalValidRate)")
        print("Optimized: \(simpleResults.tuningMetrics.optimizedValidRate)")
        print("Improvement: \(simpleResults.tuningMetrics.improvementFactor)")
        print("Gradient count: \(simpleResults.gradient.choiceGradients.count)")
        
        // Test 2: Pick generator with weighted choices
        let pickGen = Gen.pick(choices: [
            (weight: 1, Gen.choose(in: 0...30)),    // Lower range (more even numbers)
            (weight: 1, Gen.choose(in: 31...60)),   // Middle range
            (weight: 1, Gen.choose(in: 61...100))   // Upper range (fewer even numbers)
        ])
        
        let pickResults = await ChoiceGradientSampler.optimize(
            pickGen,
            for: evenProperty,
            samples: 200,
            iterations: 3
        )
        
        print("\n--- Pick Generator (weighted choices) ---")
        print("Original: \(pickResults.tuningMetrics.originalValidRate)")
        print("Optimized: \(pickResults.tuningMetrics.optimizedValidRate)")
        print("Improvement: \(pickResults.tuningMetrics.improvementFactor)")
        print("Gradient count: \(pickResults.gradient.choiceGradients.count)")
        print("Significant gradients: \(pickResults.gradient.significantChoiceCount)")
        
        // Test 3: Array generator (complex structure)
        let arrayGen = Gen.arrayOf(Gen.choose(in: 0...10), Gen.choose(in: 1...3))
        let arrayProperty: ([Int]) -> Bool = { array in
            array.count <= 2 && array.allSatisfy { $0 % 2 == 0 }
        }
        
        let arrayResults = await ChoiceGradientSampler.optimize(
            arrayGen,
            for: arrayProperty,
            samples: 200,
            iterations: 3
        )
        
        print("\n--- Array Generator (sequence structure) ---")
        print("Original: \(arrayResults.tuningMetrics.originalValidRate)")
        print("Optimized: \(arrayResults.tuningMetrics.optimizedValidRate)")
        print("Improvement: \(arrayResults.tuningMetrics.improvementFactor)")
        print("Gradient count: \(arrayResults.gradient.choiceGradients.count)")
        print("Structural patterns: \(arrayResults.gradient.structuralPatterns)")
        
        // Validate that complex generators show better CGS performance
        #expect(arrayResults.tuningMetrics.improvementFactor > simpleResults.tuningMetrics.improvementFactor)
        #expect(pickResults.gradient.significantChoiceCount > 0)
    }
    
    @Test("CGS validation testing")
    func testCGSValidationTesting() async throws {
        // Test to validate that optimized generators actually perform better
        
        let generator = Gen.pick(choices: [
            (weight: 2, Gen.choose(in: 0...20)),    // Bias toward smaller numbers
            (weight: 1, Gen.choose(in: 21...100))   // Fewer large numbers
        ])
        
        let property: (Int) -> Bool = { $0 <= 30 }  // Favor smaller numbers
        
        let optimized = await ChoiceGradientSampler.optimize(
            generator,
            for: property,
            samples: 300,
            iterations: 5
        )
        
        print("\n=== CGS Validation Test ===")
        print("Original validity: \(optimized.tuningMetrics.originalValidRate)")
        print("CGS optimized validity: \(optimized.tuningMetrics.optimizedValidRate)")
        print("Improvement factor: \(optimized.tuningMetrics.improvementFactor)")
        
        // Independent validation: compare optimized vs original generator
        let validationResult = await optimized.validateImprovement(
            against: property,
            samples: 500
        )
        
        print("Independent validation factor: \(validationResult)")
        print("Viability score: \(optimized.tuningMetrics.shrinkingViabilityScore)")
        
        // Both CGS-reported improvement and independent validation should be positive
        #expect(optimized.tuningMetrics.improvementFactor > 1.0)
        #expect(validationResult > 1.0)
    }
    
    @Test("CGS gradient debugging deep dive")
    func testCGSGradientDeepDive() async throws {
        // Detailed analysis of gradient computation for debugging
        
        let generator = Gen.pick(choices: [
            (weight: 1, Gen.choose(in: 0...25)),    // High validity range
            (weight: 1, Gen.choose(in: 26...50)),   // Medium validity range  
            (weight: 1, Gen.choose(in: 51...100))   // Low validity range
        ])
        
        let property: (Int) -> Bool = { $0 <= 30 }
        
        // Manual gradient analysis
        let valueTreeGen = ValueAndChoiceTreeGenerator(generator, maxRuns: 100)
        var samples: [(value: Int, tree: ChoiceTree, isValid: Bool)] = []
        
        for (value, tree) in valueTreeGen {
            let isValid = property(value)
            samples.append((value: value, tree: tree, isValid: isValid))
        }
        
        print("\n=== Gradient Deep Dive ===")
        print("Total samples: \(samples.count)")
        print("Valid samples: \(samples.filter { $0.isValid }.count)")
        print("Validity rate: \(Double(samples.filter { $0.isValid }.count) / Double(samples.count))")
        
        // Analyze choice tree patterns
        let validSamples = samples.filter { $0.isValid }
        let invalidSamples = samples.filter { !$0.isValid }
        
        print("\nChoice tree analysis:")
        print("Valid sample trees (first 3):")
        for sample in validSamples.prefix(3) {
            print("  Value: \(sample.value), Tree: \(sample.tree)")
        }
        
        print("Invalid sample trees (first 3):")
        for sample in invalidSamples.prefix(3) {
            print("  Value: \(sample.value), Tree: \(sample.tree)")
        }
        
        // Run CGS and compare
        let optimized = await ChoiceGradientSampler.optimize(
            generator,
            for: property,
            samples: 100,
            iterations: 3
        )
        
        print("\nCGS Results:")
        print("Improvement: \(optimized.tuningMetrics.improvementFactor)")
        print("Gradients found: \(optimized.gradient.choiceGradients.count)")
        for gradient in optimized.gradient.choiceGradients {
            print("  Path: \(gradient.choicePath), Fitness: \(gradient.fitness), Confidence: \(gradient.confidence)")
        }
        
        #expect(samples.count > 50)  // Should have generated adequate samples
    }
}