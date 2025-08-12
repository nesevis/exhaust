//
//  ChoiceGradientSamplerTests.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/8/2025.
//

import Testing
@testable import Exhaust

struct ChoiceGradientSamplerTests {
    
    @Test("CGS basic functionality")
    func testBasicCGSFunctionality() async throws {
        // Create a simple generator that should benefit from CGS
        let generator = Gen.choose(in: 0...100)
        
        // Property: only even numbers are valid
        let property: (Int) -> Bool = { $0 % 2 == 0 }
        
        // Run CGS optimization
        let optimized = await ChoiceGradientSampler.optimize(
            generator,
            for: property,
            samples: 100,
            iterations: 2
        )
        
        // Validate that we got metrics back
        #expect(optimized.tuningMetrics.originalValidRate >= 0.0)
        #expect(optimized.tuningMetrics.optimizedValidRate >= 0.0)
        #expect(optimized.tuningMetrics.improvementFactor >= 0.0)
        
        print("Original validity rate: \(optimized.tuningMetrics.originalValidRate)")
        print("Optimized validity rate: \(optimized.tuningMetrics.optimizedValidRate)")
        print("Improvement factor: \(optimized.tuningMetrics.improvementFactor)")
        print("Shrinking viability score: \(optimized.tuningMetrics.shrinkingViabilityScore)")
    }
    
    @Test("CGS metrics calculation")
    func testCGSMetricsCalculation() {
        let metrics = ChoiceGradientSampler.TuningMetrics(
            originalValidRate: 0.2,
            optimizedValidRate: 0.8,
            improvementFactor: 4.0,
            convergenceIterations: 3,
            averageGradientConfidence: 0.9,
            gradientConfidenceStdDev: 0.1,
            totalOracleCalls: 1000
        )
        
        // Test shrinking viability score computation
        let score = metrics.shrinkingViabilityScore
        #expect(score > 0.5)  // Should be high for good metrics
        #expect(score <= 1.0)  // Should be bounded
        
        print("Shrinking viability score: \(score)")
    }
    
    @Test("CGS with sparse validity condition")
    func testCGSSparseValidityCondition() async throws {
        // Create a generator with very sparse validity
        let generator = Gen.choose(in: 0...1000)
        
        // Property: only numbers divisible by 100 are valid (~1% validity rate)
        let property: (Int) -> Bool = { $0 % 100 == 0 }
        
        let optimized = await ChoiceGradientSampler.optimize(
            generator,
            for: property,
            samples: 200,
            iterations: 2
        )
        
        // Should have low viability score due to sparsity
        #expect(optimized.tuningMetrics.shrinkingViabilityScore < 0.5)
        
        print("Sparse condition viability score: \(optimized.tuningMetrics.shrinkingViabilityScore)")
    }
    
    @Test("Choice tree path creation")
    func testChoiceTreePath() {
        let path1 = ChoiceTreePath(["choice", "0", "sequence", "length"])
        let path2 = ChoiceTreePath(["choice", "0", "sequence", "length"])
        let path3 = ChoiceTreePath(["choice", "1", "sequence", "length"])
        
        #expect(path1 == path2)
        #expect(path1 != path3)
        #expect(path1.description == "choice.0.sequence.length")
    }
}