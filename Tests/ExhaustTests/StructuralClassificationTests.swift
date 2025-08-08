//
//  StructuralClassificationTests.swift
//  ExhaustTests
//
//  Created by Chris Kolbu on 8/8/2025.
//

import Testing
@testable import Exhaust

@Suite("Structural Classification Tests")
struct StructuralClassificationTests {
    
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
    
    @Test("Feature extraction produces correct vector length")
    func testFeatureVectorLength() async throws {
        let tree = ChoiceTree.choice(
            ChoiceValue.unsigned(42),
            ChoiceMetadata(validRanges: [0...100], strategies: [])
        )
        
        let featureVector = tree.toFeatureVector()
        let expectedLength = ChoiceTree.featureNames.count
        
        #expect(featureVector.count == expectedLength)
        #expect(featureVector.count == 23) // As defined in featureNames
    }
    
    @Test("Pass selection features contain expected keys")
    func testPassSelectionFeatures() async throws {
        let tree = ChoiceTree.group([
            ChoiceTree.choice(ChoiceValue.unsigned(1), ChoiceMetadata(validRanges: [0...10], strategies: [])),
            ChoiceTree.sequence(
                length: 2,
                elements: [
                    ChoiceTree.choice(ChoiceValue.unsigned(2), ChoiceMetadata(validRanges: [0...10], strategies: [])),
                    ChoiceTree.choice(ChoiceValue.unsigned(3), ChoiceMetadata(validRanges: [0...10], strategies: []))
                ],
                ChoiceMetadata(validRanges: [0...10], strategies: [])
            )
        ])
        
        let features = tree.passSelectionFeatures()
        let expectedKeys = [
            "max_depth", "choice_count", "sequence_count", "branch_count", "group_count",
            "dominant_pattern", "important_node_ratio", "avg_branching_factor", "reduction_potential",
            "complexity_q1", "complexity_median", "complexity_q3"
        ]
        
        for key in expectedKeys {
            #expect(features[key] != nil, "Missing key: \(key)")
        }
    }
    
    @Test("Boundary features analysis")
    func testBoundaryFeatures() async throws {
        let tree = ChoiceTree.choice(
            ChoiceValue.unsigned(75), // 75% through range 0...100
            ChoiceMetadata(validRanges: [0...100], strategies: [])
        )
        
        let boundaryFeatures = tree.boundaryFeatures()
        
        #expect(boundaryFeatures["avg_range_size"] as? Double == 100.0)
        #expect(boundaryFeatures["max_range_size"] as? Double == 100.0)
        #expect(boundaryFeatures["range_count"] as? Int == 1)
        
        // Range utilization should be calculated based on position in range
        let utilization = boundaryFeatures["avg_range_utilization"] as? Double ?? 0.0
        #expect(utilization > 0.0)
    }
    
    @Test("Convergence features capture important ratio")
    func testConvergenceFeatures() async throws {
        let importantChoice = ChoiceTree.important(
            ChoiceTree.choice(ChoiceValue.unsigned(5), ChoiceMetadata(validRanges: [0...10], strategies: []))
        )
        
        let tree = ChoiceTree.group([
            importantChoice,
            ChoiceTree.choice(ChoiceValue.unsigned(8), ChoiceMetadata(validRanges: [0...10], strategies: []))
        ])
        
        let convergenceFeatures = tree.convergenceFeatures()
        
        #expect(convergenceFeatures["important_node_ratio"] as? Double ?? 0.0 > 0.0)
        #expect(convergenceFeatures["structural_complexity"] != nil)
        #expect(convergenceFeatures["convergence_indicator"] != nil)
    }
    
    @Test("Range features handle multiple choices")
    func testRangeFeatures() async throws {
        let elements = [
            ChoiceTree.choice(ChoiceValue.unsigned(10), ChoiceMetadata(validRanges: [0...100], strategies: [])),
            ChoiceTree.choice(ChoiceValue.unsigned(50), ChoiceMetadata(validRanges: [0...1000], strategies: [])),
            ChoiceTree.choice(ChoiceValue.unsigned(5), ChoiceMetadata(validRanges: [0...10], strategies: []))
        ]
        
        let tree = ChoiceTree.group(elements)
        let rangeFeatures = tree.rangeFeatures()
        
        #expect(rangeFeatures["choice_count"] as? Int == 3)
        #expect(rangeFeatures["avg_range_size"] as? Double ?? 0.0 > 0.0)
        #expect(rangeFeatures["range_size_variance"] as? Double ?? 0.0 > 0.0) // Should have variance due to different range sizes
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
    
    @Test("Entropy features included in pass selection")
    func testEntropyInPassSelection() async throws {
        let tree = ChoiceTree.group([
            ChoiceTree.choice(ChoiceValue.unsigned(1), ChoiceMetadata(validRanges: [0...10], strategies: [])),
            ChoiceTree.sequence(
                length: 2,
                elements: [ChoiceTree.choice(ChoiceValue.unsigned(2), ChoiceMetadata(validRanges: [0...10], strategies: []))],
                ChoiceMetadata(validRanges: [0...10], strategies: [])
            )
        ])
        
        let passFeatures = tree.passSelectionFeatures()
        
        #expect(passFeatures["structural_entropy"] != nil)
        #expect(passFeatures["value_entropy"] != nil)
        #expect(passFeatures["branching_entropy"] != nil)
        
        // Values should be non-negative
        #expect((passFeatures["structural_entropy"] as? Double ?? -1) >= 0.0)
        #expect((passFeatures["value_entropy"] as? Double ?? -1) >= 0.0)
        #expect((passFeatures["branching_entropy"] as? Double ?? -1) >= 0.0)
    }
}

@Suite("SerializableCasePath Tests")
struct SerializableCasePathTests {
    
    @Test("Choice value path extraction")
    func testChoiceValuePath() async throws {
        let originalValue = ChoiceValue.unsigned(42)
        let tree = ChoiceTree.choice(originalValue, ChoiceMetadata(validRanges: [0...100], strategies: []))
        
        let extractedValue = ChoiceTreeCasePaths.choiceValue.extract(from: tree)
        #expect(extractedValue == originalValue)
    }
    
    @Test("Choice value path application")
    func testChoiceValueApplication() async throws {
        let originalValue = ChoiceValue.unsigned(42)
        let tree = ChoiceTree.choice(originalValue, ChoiceMetadata(validRanges: [0...100], strategies: []))
        
        let newValue = ChoiceValue.unsigned(84)
        let modifiedTree = ChoiceTreeCasePaths.choiceValue.apply(value: newValue, to: tree)
        
        #expect(modifiedTree != nil)
        if case let .choice(value, _) = modifiedTree! {
            #expect(value == newValue)
        } else {
            #expect(Bool(false), "Expected choice tree")
        }
    }
    
    @Test("Sequence length path")
    func testSequenceLengthPath() async throws {
        let elements = [ChoiceTree.choice(ChoiceValue.unsigned(1), ChoiceMetadata(validRanges: [0...10], strategies: []))]
        let tree = ChoiceTree.sequence(length: 5, elements: elements, ChoiceMetadata(validRanges: [0...10], strategies: []))
        
        let extractedLength = ChoiceTreeCasePaths.sequenceLength.extract(from: tree)
        #expect(extractedLength == 5)
        
        let modifiedTree = ChoiceTreeCasePaths.sequenceLength.apply(value: 3, to: tree)
        #expect(modifiedTree != nil)
        
        if case let .sequence(length, _, _) = modifiedTree! {
            #expect(length == 3)
        } else {
            #expect(Bool(false), "Expected sequence tree")
        }
    }
    
    @Test("Path registry lookup")
    func testPathRegistry() async throws {
        let choiceValuePath: SerializableCasePath<ChoiceTree, ChoiceValue>? = await CasePathRegistry.casePath(for: "choice.value")
        #expect(choiceValuePath != nil)
        
        let sequenceLengthPath: SerializableCasePath<ChoiceTree, UInt64>? = await CasePathRegistry.casePath(for: "sequence.length")
        #expect(sequenceLengthPath != nil)
        
        let availablePaths = await CasePathRegistry.availablePaths
        #expect(availablePaths.contains("choice.value"))
        #expect(availablePaths.contains("sequence.length"))
    }
}

@Suite("ClassifierGuidedPassRunner Tests")
struct ClassifierGuidedPassRunnerTests {
    
    @Test("Pass runner initialization")
    func testPassRunnerInit() async throws {
        let passRunner = ClassifierGuidedPassRunner()
        // Test that it initializes without throwing
        #expect(passRunner != nil)
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
        
        #expect(prediction.passStrategy.recommendedStrategy != nil)
        #expect(prediction.boundaryGuidance.refinementPotential >= 0.0)
        #expect(prediction.convergenceIndicator.convergenceConfidence >= 0.0)
        #expect(prediction.rangeRefinement.expectedImprovement >= 0.0)
    }
}

@Suite("Rule Condition Tests")
struct RuleConditionTests {
    
    @Test("Less than condition")
    func testLessThanCondition() async throws {
        let condition = RuleCondition.lessThan(10.0)
        
        #expect(condition.matches(5.0) == true)
        #expect(condition.matches(15.0) == false)
        #expect(condition.matches(10.0) == false)
    }
    
    @Test("Between condition")
    func testBetweenCondition() async throws {
        let condition = RuleCondition.between(10.0, 20.0)
        
        #expect(condition.matches(15.0) == true)
        #expect(condition.matches(10.0) == true)
        #expect(condition.matches(20.0) == true)
        #expect(condition.matches(5.0) == false)
        #expect(condition.matches(25.0) == false)
    }
    
    @Test("Equal to condition")
    func testEqualToCondition() async throws {
        let condition = RuleCondition.equalTo("test")
        
        #expect(condition.matches("test") == true)
        #expect(condition.matches("other") == false)
    }
    
    @Test("Contains condition")
    func testContainsCondition() async throws {
        let condition = RuleCondition.contains("choice")
        
        #expect(condition.matches("choice-heavy") == true)
        #expect(condition.matches("sequence-heavy") == false)
    }
}
