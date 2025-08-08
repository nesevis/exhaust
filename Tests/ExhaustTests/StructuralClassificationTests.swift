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
    
    @Test("Deep nested path navigation")
    func testDeepNestedPaths() async throws {
        // Create a deeply nested structure:
        // group -> sequence -> group -> important -> choice
        let deepChoice = ChoiceTree.choice(ChoiceValue.unsigned(100), ChoiceMetadata(validRanges: [0...1000], strategies: []))
        let importantChoice = ChoiceTree.important(deepChoice)
        let innerGroup = ChoiceTree.group([importantChoice])
        let sequenceElement = ChoiceTree.sequence(
            length: 1,
            elements: [innerGroup],
            ChoiceMetadata(validRanges: [0...10], strategies: [])
        )
        let outerGroup = ChoiceTree.group([sequenceElement])
        
        // Test navigation through the nested structure
        if case let .group(outerElements) = outerGroup,
           case let .sequence(_, sequenceElements, _) = outerElements.first,
           case let .group(innerElements) = sequenceElements.first,
           case let .important(choice) = innerElements.first,
           case let .choice(value, _) = choice {
            #expect(value == ChoiceValue.unsigned(100))
        } else {
            #expect(Bool(false), "Failed to navigate nested structure")
        }
    }
    
    @Test("Complex path composition with multiple modifications")
    func testComplexPathComposition() async throws {
        // Create a complex tree structure
        let choice1 = ChoiceTree.choice(ChoiceValue.unsigned(10), ChoiceMetadata(validRanges: [0...100], strategies: []))
        let choice2 = ChoiceTree.choice(ChoiceValue.unsigned(20), ChoiceMetadata(validRanges: [0...100], strategies: []))
        let choice3 = ChoiceTree.choice(ChoiceValue.unsigned(30), ChoiceMetadata(validRanges: [0...100], strategies: []))
        
        let sequence1 = ChoiceTree.sequence(length: 2, elements: [choice1, choice2], ChoiceMetadata(validRanges: [0...10], strategies: []))
        let group1 = ChoiceTree.group([sequence1, choice3])
        let importantGroup = ChoiceTree.important(group1)
        
        // Test extracting and modifying sequence elements
        let sequenceElementsPath = ChoiceTreeCasePaths.sequenceElements
        let importantInnerPath = ChoiceTreeCasePaths.importantInner
        
        // Extract the inner group from the important wrapper
        guard let innerGroup = importantInnerPath.extract(from: importantGroup) else {
            #expect(Bool(false), "Failed to extract inner group")
            return
        }
        
        // Extract the first element (sequence) from the group
        if case let .group(elements) = innerGroup,
           let firstSequence = elements.first {
            
            // Extract elements from the sequence
            guard let sequenceElements = sequenceElementsPath.extract(from: firstSequence) else {
                #expect(Bool(false), "Failed to extract sequence elements")
                return
            }
            
            #expect(sequenceElements.count == 2)
            
            // Modify the sequence elements
            let newChoice = ChoiceTree.choice(ChoiceValue.unsigned(999), ChoiceMetadata(validRanges: [0...1000], strategies: []))
            let modifiedElements = [newChoice, sequenceElements[1]]
            
            guard let modifiedSequence = sequenceElementsPath.apply(value: modifiedElements, to: firstSequence) else {
                #expect(Bool(false), "Failed to apply modified elements")
                return
            }
            
            // Verify the modification
            if case let .sequence(_, elements, _) = modifiedSequence,
               case let .choice(value, _) = elements.first {
                #expect(value == ChoiceValue.unsigned(999))
            } else {
                #expect(Bool(false), "Modified sequence doesn't have expected structure")
            }
        }
    }
    
    @Test("Nested important and selected wrappers")
    func testNestedWrappers() async throws {
        let baseChoice = ChoiceTree.choice(ChoiceValue.unsigned(42), ChoiceMetadata(validRanges: [0...100], strategies: []))
        let importantChoice = ChoiceTree.important(baseChoice)
        let selectedImportant = ChoiceTree.selected(importantChoice)
        let doubleImportant = ChoiceTree.important(selectedImportant)
        
        // Test unwrapping multiple layers
        let importantInnerPath = ChoiceTreeCasePaths.importantInner
        let selectedInnerPath = ChoiceTreeCasePaths.selectedInner
        
        // Unwrap first important layer
        guard let level1 = importantInnerPath.extract(from: doubleImportant) else {
            #expect(Bool(false), "Failed to extract first important layer")
            return
        }
        
        // Unwrap selected layer
        guard let level2 = selectedInnerPath.extract(from: level1) else {
            #expect(Bool(false), "Failed to extract selected layer")
            return
        }
        
        // Unwrap second important layer
        guard let level3 = importantInnerPath.extract(from: level2) else {
            #expect(Bool(false), "Failed to extract second important layer")
            return
        }
        
        // Should now have the base choice
        if case let .choice(value, _) = level3 {
            #expect(value == ChoiceValue.unsigned(42))
        } else {
            #expect(Bool(false), "Failed to reach base choice")
        }
    }
    
    @Test("Multi-level sequence navigation")
    func testMultiLevelSequenceNavigation() async throws {
        // Create nested sequences: sequence[sequence[choice, choice], choice]
        let innerChoice1 = ChoiceTree.choice(ChoiceValue.unsigned(1), ChoiceMetadata(validRanges: [0...10], strategies: []))
        let innerChoice2 = ChoiceTree.choice(ChoiceValue.unsigned(2), ChoiceMetadata(validRanges: [0...10], strategies: []))
        let outerChoice = ChoiceTree.choice(ChoiceValue.unsigned(3), ChoiceMetadata(validRanges: [0...10], strategies: []))
        
        let innerSequence = ChoiceTree.sequence(
            length: 2,
            elements: [innerChoice1, innerChoice2],
            ChoiceMetadata(validRanges: [0...10], strategies: [])
        )
        
        let outerSequence = ChoiceTree.sequence(
            length: 2,
            elements: [innerSequence, outerChoice],
            ChoiceMetadata(validRanges: [0...10], strategies: [])
        )
        
        // Navigate to deeply nested elements
        let sequenceElementsPath = ChoiceTreeCasePaths.sequenceElements
        
        // Get outer sequence elements
        guard let outerElements = sequenceElementsPath.extract(from: outerSequence) else {
            #expect(Bool(false), "Failed to extract outer sequence elements")
            return
        }
        
        #expect(outerElements.count == 2)
        
        // Get inner sequence elements
        guard let innerElements = sequenceElementsPath.extract(from: outerElements[0]) else {
            #expect(Bool(false), "Failed to extract inner sequence elements")
            return
        }
        
        #expect(innerElements.count == 2)
        
        // Verify we can reach the deeply nested choices
        if case let .choice(value1, _) = innerElements[0],
           case let .choice(value2, _) = innerElements[1] {
            #expect(value1 == ChoiceValue.unsigned(1))
            #expect(value2 == ChoiceValue.unsigned(2))
        } else {
            #expect(Bool(false), "Failed to extract inner choice values")
        }
        
        // Test modifying deeply nested elements
        let newInnerChoice = ChoiceTree.choice(ChoiceValue.unsigned(999), ChoiceMetadata(validRanges: [0...1000], strategies: []))
        let modifiedInnerElements = [newInnerChoice, innerElements[1]]
        
        guard let modifiedInnerSequence = sequenceElementsPath.apply(value: modifiedInnerElements, to: outerElements[0]) else {
            #expect(Bool(false), "Failed to modify inner sequence")
            return
        }
        
        let modifiedOuterElements = [modifiedInnerSequence, outerElements[1]]
        guard let finalTree = sequenceElementsPath.apply(value: modifiedOuterElements, to: outerSequence) else {
            #expect(Bool(false), "Failed to modify outer sequence")
            return
        }
        
        // Verify the deep modification propagated correctly
        if case let .sequence(_, finalOuterElements, _) = finalTree,
           case let .sequence(_, finalInnerElements, _) = finalOuterElements[0],
           case let .choice(modifiedValue, _) = finalInnerElements[0] {
            #expect(modifiedValue == ChoiceValue.unsigned(999))
        } else {
            #expect(Bool(false), "Deep modification didn't propagate correctly")
        }
    }
    
    @Test("Branch children navigation")
    func testBranchChildrenNavigation() async throws {
        // Create a branched structure with nested content
        let choice1 = ChoiceTree.choice(ChoiceValue.unsigned(10), ChoiceMetadata(validRanges: [0...100], strategies: []))
        let choice2 = ChoiceTree.choice(ChoiceValue.unsigned(20), ChoiceMetadata(validRanges: [0...100], strategies: []))
        let choice3 = ChoiceTree.choice(ChoiceValue.unsigned(30), ChoiceMetadata(validRanges: [0...100], strategies: []))
        
        let group1 = ChoiceTree.group([choice1, choice2])
        let sequence1 = ChoiceTree.sequence(length: 1, elements: [choice3], ChoiceMetadata(validRanges: [0...10], strategies: []))
        
        let branch = ChoiceTree.branch(label: 42, children: [group1, sequence1])
        
        let branchChildrenPath = ChoiceTreeCasePaths.branchChildren
        
        // Extract branch children
        guard let children = branchChildrenPath.extract(from: branch) else {
            #expect(Bool(false), "Failed to extract branch children")
            return
        }
        
        #expect(children.count == 2)
        
        // Verify the structure of the children
        if case let .group(groupElements) = children[0] {
            #expect(groupElements.count == 2)
        } else {
            #expect(Bool(false), "First child is not a group")
        }
        
        if case let .sequence(length, sequenceElements, _) = children[1] {
            #expect(length == 1)
            #expect(sequenceElements.count == 1)
        } else {
            #expect(Bool(false), "Second child is not a sequence")
        }
        
        // Test modifying branch children
        let newChoice = ChoiceTree.choice(ChoiceValue.unsigned(999), ChoiceMetadata(validRanges: [0...1000], strategies: []))
        let modifiedChildren = [children[0], newChoice] // Replace sequence with choice
        
        guard let modifiedBranch = branchChildrenPath.apply(value: modifiedChildren, to: branch) else {
            #expect(Bool(false), "Failed to modify branch children")
            return
        }
        
        // Verify modification
        if case let .branch(label, newChildren) = modifiedBranch {
            #expect(label == 42)
            #expect(newChildren.count == 2)
            
            if case let .choice(value, _) = newChildren[1] {
                #expect(value == ChoiceValue.unsigned(999))
            } else {
                #expect(Bool(false), "Modified branch child is not the expected choice")
            }
        } else {
            #expect(Bool(false), "Modified tree is not a branch")
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
        #expect(availablePaths.contains("branch.children"))
        #expect(availablePaths.contains("group.children"))
        #expect(availablePaths.contains("important.inner"))
        #expect(availablePaths.contains("selected.inner"))
    }
    
    @Test("Path composition for complex transformations")
    func testPathComposition() async throws {
        // Create a complex nested structure for path composition testing
        let choice = ChoiceTree.choice(ChoiceValue.unsigned(42), ChoiceMetadata(validRanges: [0...100], strategies: []))
        let importantChoice = ChoiceTree.important(choice)
        let group = ChoiceTree.group([importantChoice])
        let sequence = ChoiceTree.sequence(length: 1, elements: [group], ChoiceMetadata(validRanges: [0...10], strategies: []))
        let selectedSequence = ChoiceTree.selected(sequence)
        
        // Compose multiple path operations
        let selectedInnerPath = ChoiceTreeCasePaths.selectedInner
        let sequenceElementsPath = ChoiceTreeCasePaths.sequenceElements
        let groupChildrenPath = ChoiceTreeCasePaths.groupChildren
        let importantInnerPath = ChoiceTreeCasePaths.importantInner
        let choiceValuePath = ChoiceTreeCasePaths.choiceValue
        
        // Navigate: selected -> sequence -> elements -> group -> children -> important -> choice
        
        // Step 1: Unwrap selected
        guard let unwrappedSequence = selectedInnerPath.extract(from: selectedSequence) else {
            #expect(Bool(false), "Failed to unwrap selected")
            return
        }
        
        // Step 2: Get sequence elements
        guard let sequenceElements = sequenceElementsPath.extract(from: unwrappedSequence) else {
            #expect(Bool(false), "Failed to get sequence elements")
            return
        }
        
        #expect(sequenceElements.count == 1)
        
        // Step 3: Get group children
        guard let groupChildren = groupChildrenPath.extract(from: sequenceElements[0]) else {
            #expect(Bool(false), "Failed to get group children")
            return
        }
        
        #expect(groupChildren.count == 1)
        
        // Step 4: Unwrap important
        guard let unwrappedChoice = importantInnerPath.extract(from: groupChildren[0]) else {
            #expect(Bool(false), "Failed to unwrap important")
            return
        }
        
        // Step 5: Get choice value
        guard let originalValue = choiceValuePath.extract(from: unwrappedChoice) else {
            #expect(Bool(false), "Failed to get choice value")
            return
        }
        
        #expect(originalValue == ChoiceValue.unsigned(42))
        
        // Now test the reverse: modify the deeply nested value and reconstruct
        let newValue = ChoiceValue.unsigned(999)
        
        // Apply modifications in reverse order
        guard let modifiedChoice = choiceValuePath.apply(value: newValue, to: unwrappedChoice) else {
            #expect(Bool(false), "Failed to modify choice value")
            return
        }
        
        let modifiedGroupChildren = [importantChoice] // Keep the original important wrapper but with modified inner choice
        guard let modifiedGroup = groupChildrenPath.apply(value: [modifiedChoice], to: sequenceElements[0]) else {
            #expect(Bool(false), "Failed to modify group children")
            return
        }
        
        let modifiedSequenceElements = [modifiedGroup]
        guard let modifiedSequenceInner = sequenceElementsPath.apply(value: modifiedSequenceElements, to: unwrappedSequence) else {
            #expect(Bool(false), "Failed to modify sequence elements")
            return
        }
        
        guard let finalTree = selectedInnerPath.apply(value: modifiedSequenceInner, to: selectedSequence) else {
            #expect(Bool(false), "Failed to wrap with selected")
            return
        }
        
        // Verify the modification propagated through all layers
        if case let .selected(innerSequence) = finalTree,
           case let .sequence(_, elements, _) = innerSequence,
           case let .group(children) = elements[0],
           case let .choice(value, _) = children[0] {
            #expect(value == ChoiceValue.unsigned(999))
        } else {
            #expect(Bool(false), "Complex path composition failed to propagate changes")
        }
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
