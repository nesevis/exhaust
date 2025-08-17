//
//  CGSBranchFitnessDebug.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/8/2025.
//

import Testing
@testable import Exhaust

struct CGSBranchFitnessDebug {
    
    @Test("Debug CGS branch fitness measurement")
    func testCGSBranchFitnessDebug() async throws {
        // The same generator from testBasicCGSFunctionality
        let generator = Gen.pick(choices: [
            (weight: UInt64(3), Gen.choose(in: 0...20)),                    // ~52% valid
            (weight: UInt64(2), Gen.choose(in: 21...40)),                   // ~50% valid
            (weight: UInt64(1), Gen.choose(in: 41...100).map { $0 * 2 })    // 100% valid
        ])
        
        let property: (Int) -> Bool = { $0 % 2 == 0 }
        
        // Generate samples manually to see the branch performance
        let valueTreeGen = ValueAndChoiceTreeInterpreter(generator, maxRuns: 300)
        var branchStats: [UInt64: (total: Int, valid: Int)] = [:]
        
        for (value, tree) in valueTreeGen {
            let isValid = property(value)
            
            // Extract branch label from tree
            if let branchLabel = extractBranchLabel(from: tree) {
                let stats = branchStats[branchLabel] ?? (total: 0, valid: 0)
                branchStats[branchLabel] = (
                    total: stats.total + 1,
                    valid: stats.valid + (isValid ? 1 : 0)
                )
            }
            
            print("Value: \(value), Valid: \(isValid), Tree: \(tree)")
            if branchStats.values.map(\.total).reduce(0, +) >= 50 { break } // Stop after enough samples
        }
        
        print("\n=== Branch Performance Analysis ===")
        for (label, stats) in branchStats.sorted(by: { $0.key < $1.key }) {
            let validityRate = Double(stats.valid) / Double(stats.total)
            print("Branch \(label): \(stats.valid)/\(stats.total) valid (\(String(format: "%.1f", validityRate * 100))%)")
        }
        
        // Now run CGS and see what gradients it computes
        print("\n=== CGS Gradient Analysis ===")
        let optimized = await ChoiceGradientSampler.optimize(
            generator,
            for: property,
            samples: 200,
            iterations: 5
        )
        
        print("Gradients found: \(optimized.gradient.choiceGradients.count)")
        for gradient in optimized.gradient.choiceGradients {
            print("Path: \(gradient.choicePath)")
            print("  Fitness: \(gradient.fitness)")
            print("  Confidence: \(gradient.confidence)")
            print("  Sample count: \(gradient.sampleCount)")
        }
        
        print("Improvement factor: \(optimized.tuningMetrics.improvementFactor)")
        
        // The branch with 100% validity should have fitness = 1.0
        let perfectBranch = optimized.gradient.choiceGradients.first { $0.fitness == 1.0 }
        if let perfectBranch = perfectBranch {
            print("✅ Found perfect branch: \(perfectBranch.choicePath)")
        } else {
            print("❌ No perfect branch found - CGS not detecting 100% valid choice")
        }
        
        #expect(optimized.gradient.choiceGradients.count > 0) // Should find some gradients
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
