//
//  CGSWeightAdjustmentTest.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/8/2025.
//

import Testing
@testable import Exhaust

struct CGSWeightAdjustmentTest {
    
    @Test("Test CGS weight adjustment behavior")
    func testCGSWeightAdjustment() async throws {
        print("=== Testing CGS Weight Adjustment Behavior ===")
        
        // Create generator with explicit weights that should be dramatically adjusted
        let generator = Gen.pick(choices: [
            (weight: UInt64(10), Gen.choose(in: 0...20)),                   // ~50% valid, should be reduced
            (weight: UInt64(5), Gen.choose(in: 21...40)),                   // ~50% valid, should be reduced
            (weight: UInt64(1), Gen.choose(in: 41...100).map { $0 * 2 })   // 100% valid, should be boosted
        ])
        
        let property: (Int) -> Bool = { $0 % 2 == 0 }
        
        // Generate some baseline samples to see original distribution
        print("\n=== Original Weight Distribution ===")
        let originalGen = ValueAndChoiceTreeGenerator(generator, maxRuns: 100)
        var originalBranchCounts: [UInt64: Int] = [:]
        
        for (_, tree) in originalGen {
            if let label = extractBranchLabel(from: tree) {
                originalBranchCounts[label] = (originalBranchCounts[label] ?? 0) + 1
            }
        }
        
        for (label, count) in originalBranchCounts.sorted(by: { $0.key < $1.key }) {
            let percentage = Double(count) / 100.0 * 100.0
            print("Original Branch \(label): \(count)/100 samples (\(String(format: "%.1f", percentage))%)")
        }
        
        // Run CGS optimization with debug output (more samples to ensure Branch 3 gets enough)
        print("\n=== Running CGS Optimization ===")
        let optimized = await ChoiceGradientSampler.optimize(
            generator,
            for: property,
            samples: 500,
            iterations: 5
        )
        
        print("CGS result: \(optimized.gradient.choiceGradients.count) gradients found")
        print("CGS overall confidence: \(optimized.gradient.overallConfidence)")
        
        print("\n=== CGS Gradients ===")
        for gradient in optimized.gradient.choiceGradients {
            if gradient.choicePath.description.contains("branch.label_") {
                print("Branch gradient: \(gradient.choicePath)")
                print("  Fitness: \(String(format: "%.3f", gradient.fitness))")
                print("  Confidence: \(String(format: "%.3f", gradient.confidence))")
            }
        }
        
        // Generate samples with optimized generator to see new distribution
        print("\n=== Optimized Weight Distribution ===")
        let optimizedGen = optimized.generate(maxRuns: 100)
        var optimizedBranchCounts: [UInt64: Int] = [:]
        
        for (_, tree) in optimizedGen {
            if let label = extractBranchLabel(from: tree) {
                optimizedBranchCounts[label] = (optimizedBranchCounts[label] ?? 0) + 1
            }
        }
        
        for (label, count) in optimizedBranchCounts.sorted(by: { $0.key < $1.key }) {
            let percentage = Double(count) / 100.0 * 100.0
            let originalCount = originalBranchCounts[label] ?? 0
            let originalPercentage = Double(originalCount) / 100.0 * 100.0
            let change = percentage - originalPercentage
            let changeStr = change > 0 ? "+\(String(format: "%.1f", change))" : "\(String(format: "%.1f", change))"
            
            print("Optimized Branch \(label): \(count)/100 samples (\(String(format: "%.1f", percentage))%) [\(changeStr)%]")
        }
        
        print("\nImprovement factor: \(String(format: "%.2f", optimized.tuningMetrics.improvementFactor))")
        
        // Expectations: Branch 3 (100% valid) should dramatically increase in frequency
        // Branches 1 and 2 (~50% valid) should decrease in frequency
        let branch3Increase = (optimizedBranchCounts[3] ?? 0) - (originalBranchCounts[3] ?? 0)
        print("\nBranch 3 frequency increase: \(branch3Increase) samples")
        
        #expect(branch3Increase > 5, "Branch 3 (100% valid) should increase significantly")
        #expect(optimized.tuningMetrics.improvementFactor > 1.2, "Should see significant improvement")
    }
    
    /// Extract branch label from choice tree for debugging
    private func extractBranchLabel(from tree: ChoiceTree) -> UInt64? {
        switch tree {
        case .group(let children):
            for child in children {
                if let label = extractBranchLabel(from: child) {
                    return label
                }
            }
            return nil
            
        case .selected(let innerTree):
            return extractBranchLabel(from: innerTree)
            
        case .branch(let label, _):
            return label
            
        default:
            return nil
        }
    }
}