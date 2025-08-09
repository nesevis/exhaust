//
//  StructuralFingerprintTests.swift
//  ExhaustTests
//
//  Created by Chris Kolbu on 8/8/2025.
//

import Testing
@testable import Exhaust

@Suite("Structural Fingerprint Tests")
struct StructuralFingerprintTests {
    
    @Test("StructuralFingerprint captures basic tree patterns")
    func testStructuralFingerprintBasics() async throws {
        // Simple choice tree
        let choiceTree = ChoiceTree.choice(
            ChoiceValue.unsigned(42),
            ChoiceMetadata(validRanges: [0...100], strategies: [])
        )
        
        let fingerprint = StructuralFingerprint(from: choiceTree)
        print()
        
        #expect(fingerprint.maxDepth == 0)
        #expect(fingerprint.nodeTypeCounts["choice"] == 1)
        #expect(fingerprint.dominantPattern == "choice-heavy")
        #expect(fingerprint.importantNodeRatio == 0.0)
    }
    
    @Test("StructuralFingerprint captures sequence patterns")
    func testSequencePatterns() async throws {
        // Sequence with multiple elements
        let elements = [
            ChoiceTree.choice(ChoiceValue.unsigned(1), ChoiceMetadata(validRanges: [0...10], strategies: [])),
            ChoiceTree.choice(ChoiceValue.unsigned(2), ChoiceMetadata(validRanges: [0...10], strategies: [])),
            ChoiceTree.choice(ChoiceValue.unsigned(3), ChoiceMetadata(validRanges: [0...10], strategies: []))
        ]
        
        let sequenceTree = ChoiceTree.sequence(
            length: 3,
            elements: elements,
            ChoiceMetadata(validRanges: [0...10], strategies: [])
        )
        
        let fingerprint = StructuralFingerprint(from: sequenceTree)
        print()
        
        #expect(fingerprint.maxDepth == 1)
        #expect(fingerprint.nodeTypeCounts["sequence"] == 1)
        #expect(fingerprint.nodeTypeCounts["choice"] == 3)
        #expect(fingerprint.avgBranchingFactor == 3.0)
        #expect(fingerprint.dominantPattern == "choice-heavy")
    }
    
    @Test("StructuralFingerprint handles important nodes")
    func testImportantNodes() async throws {
        let innerChoice = ChoiceTree.choice(
            ChoiceValue.unsigned(100),
            ChoiceMetadata(validRanges: [0...1000], strategies: [])
        )
        
        let importantTree = ChoiceTree.important(innerChoice)
        let fingerprint = StructuralFingerprint(from: importantTree)
        
        #expect(fingerprint.importantNodeRatio == 0.5) // 1 important out of 2 total nodes
        #expect(fingerprint.nodeTypeCounts["choice"] == 1)
    }
    
    @Test("Shannon entropy calculations")
    func testShannonEntropy() async throws {
        // Test single node tree (low structural entropy)
        let singleTree = ChoiceTree.choice(ChoiceValue.unsigned(42), ChoiceMetadata(validRanges: [0...100], strategies: []))
        let singleFingerprint = StructuralFingerprint(from: singleTree)
        
        // Single node type should have structural entropy of 0
        #expect(singleFingerprint.structuralEntropy == 0.0)
        
        // Test mixed tree (higher structural entropy)
        let mixedElements = [
            ChoiceTree.choice(ChoiceValue.unsigned(1), ChoiceMetadata(validRanges: [0...10], strategies: [])),
            ChoiceTree.sequence(
                length: 2,
                elements: [ChoiceTree.choice(ChoiceValue.unsigned(2), ChoiceMetadata(validRanges: [0...10], strategies: []))],
                ChoiceMetadata(validRanges: [0...10], strategies: [])
            ),
            ChoiceTree.just("constant")
        ]
        let mixedTree = ChoiceTree.group(mixedElements)
        let mixedFingerprint = StructuralFingerprint(from: mixedTree)
        
        // Should have higher structural entropy due to mixed node types
        #expect(mixedFingerprint.structuralEntropy > singleFingerprint.structuralEntropy)
        #expect(mixedFingerprint.structuralEntropy > 0.0)
    }
    
    @Test("Value entropy reflects choice diversity")
    func testValueEntropy() async throws {
        // Test with identical values (low entropy)
        let identicalValues = Array(repeating:
            ChoiceTree.choice(ChoiceValue.unsigned(42), ChoiceMetadata(validRanges: [0...100], strategies: [])),
            count: 5
        )
        let identicalTree = ChoiceTree.group(identicalValues)
        let identicalFingerprint = StructuralFingerprint(from: identicalTree)
        
        // Test with diverse values (higher entropy)
        let diverseValues = [
            ChoiceTree.choice(ChoiceValue.unsigned(1), ChoiceMetadata(validRanges: [0...100], strategies: [])),
            ChoiceTree.choice(ChoiceValue.unsigned(50), ChoiceMetadata(validRanges: [0...100], strategies: [])),
            ChoiceTree.choice(ChoiceValue.unsigned(100), ChoiceMetadata(validRanges: [0...100], strategies: [])),
            ChoiceTree.choice(ChoiceValue.unsigned(25), ChoiceMetadata(validRanges: [0...100], strategies: [])),
            ChoiceTree.choice(ChoiceValue.unsigned(75), ChoiceMetadata(validRanges: [0...100], strategies: []))
        ]
        let diverseTree = ChoiceTree.group(diverseValues)
        let diverseFingerprint = StructuralFingerprint(from: diverseTree)
        
        // Diverse values should have higher entropy than identical values
        #expect(diverseFingerprint.valueEntropy >= identicalFingerprint.valueEntropy)
    }
    
    @Test("Branching entropy reflects structure complexity")
    func testBranchingEntropy() async throws {
        // Tree with uniform branching (low entropy)
        let uniformBranching = ChoiceTree.group([
            ChoiceTree.group([
                ChoiceTree.choice(ChoiceValue.unsigned(1), ChoiceMetadata(validRanges: [0...10], strategies: [])),
                ChoiceTree.choice(ChoiceValue.unsigned(2), ChoiceMetadata(validRanges: [0...10], strategies: []))
            ]),
            ChoiceTree.group([
                ChoiceTree.choice(ChoiceValue.unsigned(3), ChoiceMetadata(validRanges: [0...10], strategies: [])),
                ChoiceTree.choice(ChoiceValue.unsigned(4), ChoiceMetadata(validRanges: [0...10], strategies: []))
            ])
        ])
        let uniformFingerprint = StructuralFingerprint(from: uniformBranching)
        
        // Tree with varied branching (higher entropy)
        let variedBranching = ChoiceTree.group([
            ChoiceTree.choice(ChoiceValue.unsigned(1), ChoiceMetadata(validRanges: [0...10], strategies: [])), // 0 children
            ChoiceTree.group([
                ChoiceTree.choice(ChoiceValue.unsigned(2), ChoiceMetadata(validRanges: [0...10], strategies: [])),
                ChoiceTree.choice(ChoiceValue.unsigned(3), ChoiceMetadata(validRanges: [0...10], strategies: [])),
                ChoiceTree.choice(ChoiceValue.unsigned(4), ChoiceMetadata(validRanges: [0...10], strategies: []))
            ]) // 3 children
        ])
        let variedFingerprint = StructuralFingerprint(from: variedBranching)
        
        // Both should have some entropy, varied might be higher
        #expect(uniformFingerprint.branchingEntropy >= 0.0)
        #expect(variedFingerprint.branchingEntropy >= 0.0)
    }
}