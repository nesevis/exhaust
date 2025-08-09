//
//  ClassifierGuidedPassRunnerTests.swift
//  ExhaustTests
//
//  Created by Chris Kolbu on 8/8/2025.
//

import Testing
@testable import Exhaust

@Suite("ClassifierGuidedPassRunner Tests")
struct ClassifierGuidedPassRunnerTests {
    
    @Test("Pass runner initialization")
    func testPassRunnerInit() async throws {
        let passRunner = ClassifierGuidedPassRunner()
        // Test that it initializes without throwing
        #expect(type(of: passRunner) == ClassifierGuidedPassRunner.self)
    }
    
    @Test("Strategy prediction for sequence-heavy tree")
    func testSequenceHeavyPrediction() async throws {
        let elements = Array(repeating: 
            ChoiceTree.choice(ChoiceValue.unsigned(1), ChoiceMetadata(validRanges: [0...10], strategies: [])), 
            count: 5
        )
        
        let tree = ChoiceTree.sequence(
            length: 5,
            elements: elements,
            ChoiceMetadata(validRanges: [0...10], strategies: [])
        )
        
        let passRunner = ClassifierGuidedPassRunner()
        let strategy = await passRunner.selectOptimalPass(for: tree) { _ in true }
        
        // Should recommend sequence reduction for sequence-heavy trees
        #expect(strategy == .sequenceReduction)
    }
    
    @Test("Coordinated prediction contains all components")
    func testCoordinatedPrediction() async throws {
        let tree = ChoiceTree.choice(ChoiceValue.unsigned(50), ChoiceMetadata(validRanges: [0...100], strategies: []))
        let passRunner = ClassifierGuidedPassRunner()
        
        let prediction = await passRunner.classifyInParallel(tree)
        
        // Verify the prediction contains all required components
        #expect(prediction.boundaryGuidance.refinementPotential >= 0.0)
        #expect(prediction.convergenceIndicator.convergenceConfidence >= 0.0)
        #expect(prediction.rangeRefinement.expectedImprovement >= 0.0)
    }
}