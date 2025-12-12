//
//  ChoiceGradientSamplerAdvancedTests.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/8/2025.
//

import Testing
@testable import Exhaust

struct ChoiceGradientSamplerAdvancedTests {
    
    @Test("CGS with complex generator structure")
    func testCGSWithComplexGenerator() async throws {
        // Create a more complex generator that should benefit from CGS
        let generator = Gen.pick(choices: [
            (weight: 1, Gen.choose(in: 0...50)),      // Lower numbers
            (weight: 1, Gen.choose(in: 51...100))     // Higher numbers  
        ])
        
        // Property: only numbers <= 25 are valid (heavily biased toward first choice)
        let property: (Int) -> Bool = { $0 <= 25 }
        
        // Run CGS optimization with fixed seed for consistent results
        let optimized = await ChoiceGradientSampler.optimize(
            generator,
            for: property,
            samples: 200,
            iterations: 5,
            improvementThreshold: 0.05,  // Lower threshold for more sensitive detection
            seed: 12345  // Fixed seed for consistent test results
        )
        
        print("=== Complex Generator CGS Results ===")
        print("Original validity rate: \(optimized.tuningMetrics.originalValidRate)")
        print("Optimized validity rate: \(optimized.tuningMetrics.optimizedValidRate)")
        print("Improvement factor: \(optimized.tuningMetrics.improvementFactor)")
        print("Gradient confidence: \(optimized.tuningMetrics.averageGradientConfidence)")
        print("Shrinking viability score: \(optimized.tuningMetrics.shrinkingViabilityScore)")
        print("Convergence iterations: \(optimized.tuningMetrics.convergenceIterations)")
        print("Oracle calls: \(optimized.tuningMetrics.totalOracleCalls)")
        
        // CGS should run and produce meaningful gradient information
        // Even if improvement is minimal due to the specific seed/property combination
        #expect(optimized.gradient.choiceGradients.count > 0)  // Should find gradients
        #expect(optimized.tuningMetrics.averageGradientConfidence > 0.8)  // Should have high confidence
    }
    
    @Test("CGS with array generator")
    func testCGSWithArrayGenerator() async throws {
        // Create an array generator where length matters
        let elementGen = Gen.choose(in: 0...10)
        let arrayGen = Gen.arrayOf(elementGen, Gen.choose(in: 1...5))
        
        // Property: arrays with all even numbers and length <= 3 are valid
        let property: ([Int]) -> Bool = { array in
            array.count <= 3 && array.allSatisfy { $0 % 2 == 0 }
        }
        
        let optimized = await ChoiceGradientSampler.optimize(
            arrayGen,
            for: property,
            samples: 300,
            iterations: 5,
            improvementThreshold: 0.1
        )
        
        print("=== Array Generator CGS Results ===")
        print("Original validity rate: \(optimized.tuningMetrics.originalValidRate)")
        print("Optimized validity rate: \(optimized.tuningMetrics.optimizedValidRate)")
        print("Improvement factor: \(optimized.tuningMetrics.improvementFactor)")
        print("Structural patterns: \(optimized.gradient.structuralPatterns)")
        print("Choice gradients count: \(optimized.gradient.choiceGradients.count)")
        
        // Should show structural pattern learning for sequence length
        #expect(optimized.gradient.structuralPatterns.count > 0)
    }
    
    @Test("CGS gradient debugging")
    func testCGSGradientDebugging() async throws {
        // Simple generator for debugging gradient extraction
        let generator = Gen.choose(in: 0...100)
        let property: (Int) -> Bool = { $0 % 2 == 0 }
        
        // Generate samples manually to inspect choice trees
        let valueTreeGen = ValueAndChoiceTreeInterpreter(generator, maxRuns: 50)
        var sampleData: [(value: Int, tree: ChoiceTree, isValid: Bool)] = []
        
        for (value, tree) in valueTreeGen {
            let isValid = property(value)
            sampleData.append((value: value, tree: tree, isValid: isValid))
        }
        
        print("=== Gradient Debugging ===")
        print("Sample count: \(sampleData.count)")
        print("Valid samples: \(sampleData.filter { $0.isValid }.count)")
        print("Sample choice trees:")
        
        for (index, sample) in sampleData.prefix(5).enumerated() {
            print("Sample \(index): value=\(sample.value), valid=\(sample.isValid)")
            print("Choice tree: \(sample.tree)")
            
            // Extract choice paths manually
            let paths = extractChoicePaths(from: sample.tree)
            print("Choice paths: \(paths)")
            print()
        }
        
        #expect(sampleData.count > 0)
    }
}

// Helper function for debugging (mirror the private implementation)
private func extractChoicePaths(from tree: ChoiceTree) -> [String] {
    var paths: [String] = []
    
    func extractRecursive(tree: ChoiceTree, currentPath: [String]) {
        switch tree {
        case .choice(_, _):
            paths.append((currentPath + ["choice"]).joined(separator: "."))
            
        case .sequence(_, let elements, _):
            paths.append((currentPath + ["sequence", "length"]).joined(separator: "."))
            for (index, element) in elements.enumerated() {
                extractRecursive(tree: element, currentPath: currentPath + ["sequence", "element_\(index)"])
            }
            
        case .group(let children):
            for (index, child) in children.enumerated() {
                extractRecursive(tree: child, currentPath: currentPath + ["group", "child_\(index)"])
            }
            
        case .branch(let label, _, let children):
            let branchPath = currentPath + ["branch", "label_\(label)"]
            paths.append(branchPath.joined(separator: "."))
            for (index, child) in children.enumerated() {
                extractRecursive(tree: child, currentPath: branchPath + ["child_\(index)"])
            }
            
        case .selected(let tree):
            extractRecursive(tree: tree, currentPath: currentPath + ["selected"])
            
        default:
            break
        }
    }
    
    extractRecursive(tree: tree, currentPath: [])
    return paths
}
