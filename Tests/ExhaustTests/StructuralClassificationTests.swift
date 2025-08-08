//
//  StructuralClassificationTests.swift
//  ExhaustTests
//
//  Created by Chris Kolbu on 8/8/2025.
//
//  This file serves as an umbrella test suite for structural classification.
//  Individual test areas have been split into focused files:
//  
//  - StructuralFingerprintTests.swift - Core fingerprinting and entropy calculations
//  - FeatureExtractionTests.swift - Feature extraction for ML classification
//  - SerializableCasePathTests.swift - Swift Case Paths navigation and modification
//  - ClassifierGuidedPassRunnerTests.swift - Pass runner framework
//  - RuleConditionTests.swift - Rule condition matching logic

import Testing
@testable import Exhaust

@Suite("Structural Classification Overview")
struct StructuralClassificationTests {
    
    @Test("Classification system integration test")
    func testClassificationSystemIntegration() async throws {
        // Create a complex tree to test full system integration
        let complexTree = ChoiceTree.group([
            ChoiceTree.important(
                ChoiceTree.choice(ChoiceValue.unsigned(42), ChoiceMetadata(validRanges: [0...100], strategies: []))
            ),
            ChoiceTree.sequence(
                length: 3,
                elements: [
                    ChoiceTree.choice(ChoiceValue.unsigned(1), ChoiceMetadata(validRanges: [0...10], strategies: [])),
                    ChoiceTree.choice(ChoiceValue.unsigned(2), ChoiceMetadata(validRanges: [0...10], strategies: [])),
                    ChoiceTree.choice(ChoiceValue.unsigned(3), ChoiceMetadata(validRanges: [0...10], strategies: []))
                ],
                ChoiceMetadata(validRanges: [0...10], strategies: [])
            ),
            ChoiceTree.branch(label: 1, children: [
                ChoiceTree.choice(ChoiceValue.unsigned(10), ChoiceMetadata(validRanges: [0...20], strategies: [])),
                ChoiceTree.choice(ChoiceValue.unsigned(20), ChoiceMetadata(validRanges: [0...20], strategies: []))
            ])
        ])
        
        // Test fingerprinting
        let fingerprint = StructuralFingerprint(from: complexTree)
        #expect(fingerprint.maxDepth > 0)
        #expect(fingerprint.nodeTypeCounts["choice"]! > 0)
        #expect(fingerprint.nodeTypeCounts["sequence"]! > 0)
        #expect(fingerprint.nodeTypeCounts["branch"]! > 0)
        #expect(fingerprint.nodeTypeCounts["group"]! > 0)
        #expect(fingerprint.importantNodeRatio > 0.0)
        
        // Test feature extraction
        let features = complexTree.passSelectionFeatures()
        #expect(features.count >= 12) // Should have at least the basic feature set
        #expect(features["structural_entropy"] as? Double != nil)
        #expect(features["value_entropy"] as? Double != nil)
        #expect(features["branching_entropy"] as? Double != nil)
        
        // Test case path navigation
        let groupChildrenPath = ChoiceTreeCasePaths.groupChildren
        let extractedChildren = groupChildrenPath.extract(from: complexTree)
        #expect(extractedChildren?.count == 3)
        
        // Test pass runner
        let passRunner = ClassifierGuidedPassRunner()
        let strategy = await passRunner.selectOptimalPass(for: complexTree) { _ in true }
        #expect(strategy != nil)
        
        // Test rule conditions
        let condition = RuleCondition.greaterThan(0.5)
        let importantRatio = fingerprint.importantNodeRatio
        #expect(condition.matches(importantRatio) == (importantRatio > 0.5))
    }
}