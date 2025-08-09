//
//  SerializableCasePathTests.swift
//  ExhaustTests
//
//  Created by Chris Kolbu on 8/8/2025.
//

@testable import Exhaust
import Foundation
import See5
import Testing

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
        let choiceValuePath: SerializableChoiceTreePath<ChoiceValue>? = await CasePathRegistry.casePath(for: "choice.value")
        #expect(choiceValuePath != nil)
        
        let sequenceLengthPath: SerializableChoiceTreePath<UInt64>? = await CasePathRegistry.casePath(for: "sequence.length")
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
    
    @Test("Dynamic schema generation")
    func testDynamicSchemaGeneration() async throws {
        // Create diverse tree structures that would have different available paths
        let tree1 = ChoiceTree.choice(ChoiceValue.unsigned(42), ChoiceMetadata(validRanges: [0...100], strategies: []))
        
        let tree2 = ChoiceTree.sequence(
            length: 3,
            elements: [
                .choice(ChoiceValue.unsigned(1), ChoiceMetadata(validRanges: [0...10], strategies: [])),
                .choice(ChoiceValue.unsigned(2), ChoiceMetadata(validRanges: [0...10], strategies: []))
            ],
            ChoiceMetadata(validRanges: [0...10], strategies: [])
        )
        
        let tree3 = ChoiceTree.branch(
            label: 5,
            children: [
                .group([.choice(ChoiceValue.unsigned(10), ChoiceMetadata(validRanges: [0...100], strategies: []))]),
                .important(.choice(ChoiceValue.unsigned(20), ChoiceMetadata(validRanges: [0...100], strategies: [])))
            ]
        )
        
        let trees = [tree1, tree2, tree3]
        
        // Generate dynamic schema
        let schema = DynamicChoiceTreeSchema.generateSchema(from: trees)
        
        #expect(schema.features.count > 0)
        
        // Verify some expected features exist
        let featureNames = schema.features.map(\.name)
        #expect(featureNames.contains("choice"))
        #expect(featureNames.contains("sequence_length"))
        #expect(featureNames.contains("branch_label"))
        
        // Test feature extraction with missing values
        let features1 = schema.extractFeatures(from: tree1)
        let features2 = schema.extractFeatures(from: tree2)
        let features3 = schema.extractFeatures(from: tree3)
        
        #expect(features1.count == schema.features.count)
        #expect(features2.count == schema.features.count)
        #expect(features3.count == schema.features.count)
        
        // tree1 should have "?" for sequence/branch-specific features
        #expect(features1.contains("?"))
        
        // tree2 should have actual sequence length
        if let sequenceLengthIndex = schema.features.firstIndex(where: { $0.name == "sequence_length" }) {
            #expect(features2[sequenceLengthIndex] == "3")
        }
        
        // tree3 should have actual branch label
        if let branchLabelIndex = schema.features.firstIndex(where: { $0.name == "branch_label" }) {
            #expect(features3[branchLabelIndex] == "5")
        }
    }
    
    @Test("Dynamic classification data case creation")
    func testClassificationDataCaseCreation() async throws {
        let passingTree = ChoiceTree.choice(ChoiceValue.unsigned(5), ChoiceMetadata(validRanges: [0...10], strategies: []))
        let failingTree = ChoiceTree.sequence(
            length: 100,
            elements: [.choice(ChoiceValue.unsigned(999), ChoiceMetadata(validRanges: [0...1000], strategies: []))],
            ChoiceMetadata(validRanges: [0...200], strategies: [])
        )
        
        let trees = [passingTree, failingTree]
        let schema = DynamicChoiceTreeSchema.generateSchema(from: trees)
        
        // Create labeled cases
        let labeledCases = schema.createLabeledCases(from: [
            (passingTree, "pass"),
            (failingTree, "fail")
        ])
        
        #expect(labeledCases.count == 2)
        #expect(labeledCases[0].targetClass == "pass")
        #expect(labeledCases[1].targetClass == "fail")
        #expect(labeledCases[0].values.count == schema.features.count)
        #expect(labeledCases[1].values.count == schema.features.count)
        
        // Verify that different trees have different feature values where expected
        let passingFeatures = labeledCases[0].values
        let failingFeatures = labeledCases[1].values
        
        // They should differ in at least some features
        let differingFeatures = zip(passingFeatures, failingFeatures).filter { $0.0 != $0.1 }
        #expect(differingFeatures.count > 0)
    }
    
    @Test("Deep nested path extraction")
    func testDeepNestedPathExtraction() async throws {
        // Create a deeply nested structure: important(selected(group([sequence(elements: [choice])])))
        let deepChoice = ChoiceTree.choice(ChoiceValue.unsigned(42), ChoiceMetadata(validRanges: [0...100], strategies: []))
        let sequence = ChoiceTree.sequence(
            length: 1,
            elements: [deepChoice],
            ChoiceMetadata(validRanges: [0...10], strategies: [])
        )
        let group = ChoiceTree.group([sequence])
        let selected = ChoiceTree.selected(group)
        let important = ChoiceTree.important(selected)
        
        let trees = [important]
        let schema = DynamicChoiceTreeSchema.generateSchema(from: trees)
        
        // Should generate path like: important.selected.group.children.0.sequence.elements.0.choice
        let features = schema.extractFeatures(from: important)
        
        // Find the deeply nested choice value
        let choiceFeatureIndex = schema.features.firstIndex { feature in
            feature.path.contains("choice") && !feature.path.contains("?")
        }
        
        if let index = choiceFeatureIndex {
            #expect(features[index] == "42")
        }
        
        // Verify the path structure makes sense
        let deepPaths = schema.features.filter { $0.path.contains("important.selected.group") }
        #expect(deepPaths.count > 0)
    }
    
    @Test("See5 DataSchema conversion")
    func testSee5DataSchemaConversion() async throws {
        // Create sample trees with diverse structures
        let tree1 = ChoiceTree.choice(ChoiceValue.unsigned(42), ChoiceMetadata(validRanges: [0...100], strategies: []))
        let tree2 = ChoiceTree.sequence(
            length: 5,
            elements: [.choice(ChoiceValue.unsigned(1), ChoiceMetadata(validRanges: [0...10], strategies: []))],
            ChoiceMetadata(validRanges: [0...10], strategies: [])
        )
        let tree3 = ChoiceTree.branch(label: 3, children: [tree1])
        
        let trees = [tree1, tree2, tree3]
        let schema = DynamicChoiceTreeSchema.generateSchema(from: trees)
        
        // Convert to See5 DataSchema
        let classes = ["pass", "fail"]
        let see5Schema = schema.toSee5DataSchema(classes: classes, fromTrees: trees)
        
        #expect(see5Schema.classes == classes)
        #expect(see5Schema.attributes.count == schema.features.count)
        
        // Verify attribute names match
        let see5AttributeNames = see5Schema.attributes.map(\.name)
        let dynamicAttributeNames = schema.features.map(\.name)
        #expect(see5AttributeNames == dynamicAttributeNames)
        
        // Test See5 labeled case creation
        let see5Cases = schema.createSee5LabeledCases(from: [
            (tree1, "pass"),
            (tree2, "fail"),
            (tree3, "pass")
        ])
        
        #expect(see5Cases.count == 3)
        #expect(see5Cases[0].targetClass == "pass")
        #expect(see5Cases[1].targetClass == "fail")
        #expect(see5Cases[2].targetClass == "pass")
        
        // Each case should have the same number of attribute values as schema attributes
        for see5Case in see5Cases {
            #expect(see5Case.values.count == see5Schema.attributes.count)
        }
        
        // Verify that missing values are properly handled as nil
        let missingValueCount = see5Cases.flatMap(\.values).filter { $0 == nil }.count
        #expect(missingValueCount > 0) // Should have some missing values due to structural differences
    }
    
    @Test("Classification end to end")
    func testClassificationEndToEnd() async throws {
        typealias FiveTuple = ([Int16], [Int16], [Int16], [Int16], [Int16])
        let arrayGen = Gen.arrayOf(Int16.arbitrary, within: 1...10)
//        let gen = Gen.zip(arrayGen, arrayGen, arrayGen, arrayGen, arrayGen)
//        
//        let property = { (value: FiveTuple) in
//            let sum1 = value.0.reduce(0, (&+))
//            let sum2 = value.1.reduce(0, (&+))
//            let sum3 = value.2.reduce(0, (&+))
//            let sum4 = value.3.reduce(0, (&+))
//            let sum5 = value.4.reduce(0, (&+))
//            let arr = [sum1, sum2, sum3, sum4, sum5]
//            if arr.allSatisfy({ $0 < 256 }) {
//                return arr.reduce(0, &+) < (arr.count * 256)
//            }
//            return false
//        }
        
        typealias Tuple = (Int, Int)
        let limitedIntGen = Gen.choose(in: -500...500)
        let gen = Gen.zip(limitedIntGen, limitedIntGen)
        let property: (Tuple) -> Bool = { pair in
            pair.0 >= pair.1
        }
        var generator = ValueAndChoiceTreeGenerator(gen, maxRuns: 200)
        var passes = [ChoiceTree]()
        var fails = [ChoiceTree]()
        while let (next, choiceTree) = generator.next() {
            let passed = property(next)
            if passed {
                passes.append(choiceTree)
            } else {
                fails.append(choiceTree)
            }
        }
        let schema = DynamicChoiceTreeSchema.generateSchema(from: passes + fails)
        let dataSchema = schema.toSee5DataSchema(classes: ["pass", "fail"])
        let cases = schema.createSee5LabeledCases(from: passes.map { ($0, "pass") })
            + schema.createSee5LabeledCases(from: fails.map { ($0, "fail") })
        
        let trainingData = TrainingData(cases: cases)
        
        let classifier = try await C50Classifier(schema: dataSchema)
        
        let startTime = Date()
        
        try await classifier.train(data: trainingData, options: .init(algorithm: .rules))
        
        let duration4 = Date().timeIntervalSince(startTime)
        print("Finished training on data after \(duration4 * 1000)ms")
        
        guard
            let modelData = await classifier.trainedModel?.modelData,
            let output = String(data: modelData, encoding: .utf8)
        else {
            fatalError()
        }
        print(output)
        var mutable = output[...]
        let rules = See5Parser.parse(source: &mutable)
        print(rules)
        print()
    }
    
    @Test("Complete classification workflow")
    func testCompleteClassificationWorkflow() async throws {
        // Simulate a property-based testing scenario
        let passingTrees = [
            ChoiceTree.choice(ChoiceValue.unsigned(5), ChoiceMetadata(validRanges: [0...10], strategies: [])),
            ChoiceTree.sequence(length: 2, elements: [
                .choice(ChoiceValue.unsigned(1), ChoiceMetadata(validRanges: [0...5], strategies: []))
            ], ChoiceMetadata(validRanges: [0...5], strategies: []))
        ]
        
        let failingTrees = [
            ChoiceTree.choice(ChoiceValue.unsigned(99), ChoiceMetadata(validRanges: [0...100], strategies: [])),
            ChoiceTree.sequence(length: 50, elements: [
                .choice(ChoiceValue.unsigned(999), ChoiceMetadata(validRanges: [0...1000], strategies: []))
            ], ChoiceMetadata(validRanges: [0...100], strategies: []))
        ]
        
        let allTrees = passingTrees + failingTrees
        
        // Generate dynamic schema from all trees
        let schema = DynamicChoiceTreeSchema.generateSchema(from: allTrees)
        
        // Create training data
        var treesWithClasses: [(ChoiceTree, String)] = []
        treesWithClasses.append(contentsOf: passingTrees.map { ($0, "pass") })
        treesWithClasses.append(contentsOf: failingTrees.map { ($0, "fail") })
        
        // Convert to See5 format
        let classes = ["pass", "fail"]
        let see5Schema = schema.toSee5DataSchema(classes: classes, fromTrees: allTrees)
        let see5TrainingCases = schema.createSee5LabeledCases(from: treesWithClasses)
        
        // Verify the complete pipeline
        #expect(see5Schema.classes.contains("pass"))
        #expect(see5Schema.classes.contains("fail"))
        #expect(see5TrainingCases.count == 4) // 2 passing + 2 failing
        
        // Verify that different tree types produce different feature patterns
        let passingFeatures = see5TrainingCases.filter { $0.targetClass == "pass" }
        let failingFeatures = see5TrainingCases.filter { $0.targetClass == "fail" }
        
        #expect(passingFeatures.count == 2)
        #expect(failingFeatures.count == 2)
        
        // This demonstrates the complete workflow from ChoiceTree -> DynamicSchema -> See5 format
        // ready for C5.0 classifier training
    }
    
    @Test("Consistent field ordering across multiple schema generations")
    func testConsistentFieldOrdering() async throws {
        // Create the same trees in different orders to test ordering consistency
        let tree1 = ChoiceTree.choice(ChoiceValue.unsigned(42), ChoiceMetadata(validRanges: [0...100], strategies: []))
        let tree2 = ChoiceTree.sequence(
            length: 5,
            elements: [
                .choice(ChoiceValue.unsigned(1), ChoiceMetadata(validRanges: [0...10], strategies: [])),
                .choice(ChoiceValue.unsigned(2), ChoiceMetadata(validRanges: [0...10], strategies: []))
            ],
            ChoiceMetadata(validRanges: [0...10], strategies: [])
        )
        let tree3 = ChoiceTree.branch(label: 3, children: [tree1])
        
        // Generate schema with trees in different orders
        let schema1 = DynamicChoiceTreeSchema.generateSchema(from: [tree1, tree2, tree3])
        let schema2 = DynamicChoiceTreeSchema.generateSchema(from: [tree3, tree1, tree2])
        let schema3 = DynamicChoiceTreeSchema.generateSchema(from: [tree2, tree3, tree1])
        
        // Field names and order should be identical regardless of tree input order
        let featureNames1 = schema1.features.map(\.name)
        let featureNames2 = schema2.features.map(\.name)
        let featureNames3 = schema3.features.map(\.name)
        
        #expect(featureNames1 == featureNames2)
        #expect(featureNames2 == featureNames3)
        #expect(featureNames1 == featureNames3)
        
        // Paths should also be in identical order
        let featurePaths1 = schema1.features.map(\.path)
        let featurePaths2 = schema2.features.map(\.path)
        let featurePaths3 = schema3.features.map(\.path)
        
        #expect(featurePaths1 == featurePaths2)
        #expect(featurePaths2 == featurePaths3)
        #expect(featurePaths1 == featurePaths3)
        
        // Feature extraction should produce consistent vectors
        let features1_tree1 = schema1.extractFeatures(from: tree1)
        let features2_tree1 = schema2.extractFeatures(from: tree1)
        let features3_tree1 = schema3.extractFeatures(from: tree1)
        
        #expect(features1_tree1 == features2_tree1)
        #expect(features2_tree1 == features3_tree1)
        
        // Verify numeric ordering: sequence.elements.0 should come before sequence.elements.1
        let sequenceElementPaths = featurePaths1.filter { $0.contains("sequence.elements") }
        let sortedExpected = sequenceElementPaths.sorted()
        #expect(sequenceElementPaths == sortedExpected, "Sequence element paths should be in numeric order")
        
        // Test discrete value ordering consistency
        let discreteTree = ChoiceTree.branch(label: 5, children: [
            .choice(ChoiceValue.unsigned(1), ChoiceMetadata(validRanges: [0...10], strategies: [])),
            .choice(ChoiceValue.unsigned(3), ChoiceMetadata(validRanges: [0...10], strategies: [])),
            .choice(ChoiceValue.unsigned(2), ChoiceMetadata(validRanges: [0...10], strategies: []))
        ])
        
        let treesWithDiscrete = [tree1, tree2, discreteTree]
        let schemaA = DynamicChoiceTreeSchema.generateSchema(from: treesWithDiscrete)
        let schemaB = DynamicChoiceTreeSchema.generateSchema(from: treesWithDiscrete.reversed())
        
        let see5SchemaA = schemaA.toSee5DataSchema(classes: ["pass", "fail"], fromTrees: treesWithDiscrete)
        let see5SchemaB = schemaB.toSee5DataSchema(classes: ["pass", "fail"], fromTrees: treesWithDiscrete.reversed())
        
        // Discrete value arrays should be consistently sorted
        #expect(see5SchemaA.attributes.count == see5SchemaB.attributes.count)
        for (attrA, attrB) in zip(see5SchemaA.attributes, see5SchemaB.attributes) {
            #expect(attrA.name == attrB.name)
            #expect(attrA.type == attrB.type)
        }
    }
    
    @Test("Sequence element alignment and padding behavior")
    func testSequenceElementAlignment() async throws {
        // Create sequences of different lengths to test padding behavior
        let shortSequence = ChoiceTree.sequence(
            length: 2,
            elements: [
                .choice(ChoiceValue.unsigned(10), ChoiceMetadata(validRanges: [0...100], strategies: [])),
                .choice(ChoiceValue.unsigned(20), ChoiceMetadata(validRanges: [0...100], strategies: []))
            ],
            ChoiceMetadata(validRanges: [0...10], strategies: [])
        )
        
        let longSequence = ChoiceTree.sequence(
            length: 4,
            elements: [
                .choice(ChoiceValue.unsigned(100), ChoiceMetadata(validRanges: [0...1000], strategies: [])),
                .choice(ChoiceValue.unsigned(200), ChoiceMetadata(validRanges: [0...1000], strategies: [])),
                .choice(ChoiceValue.unsigned(300), ChoiceMetadata(validRanges: [0...1000], strategies: [])),
                .choice(ChoiceValue.unsigned(400), ChoiceMetadata(validRanges: [0...1000], strategies: []))
            ],
            ChoiceMetadata(validRanges: [0...10], strategies: [])
        )
        
        let trees = [shortSequence, longSequence]
        let schema = DynamicChoiceTreeSchema.generateSchema(from: trees)
        
        // Extract features and examine the alignment
        let shortFeatures = schema.extractFeatures(from: shortSequence)
        let longFeatures = schema.extractFeatures(from: longSequence)
        
        #expect(shortFeatures.count == longFeatures.count)
        
        // Find sequence element feature indices
        let sequenceElementFeatures = schema.features.enumerated().filter { _, feature in
            feature.path.contains("sequence.elements")
        }
        
        print("Schema paths:")
        for (index, feature) in schema.features.enumerated() {
            print("  [\(index)] \(feature.path)")
        }
        
        print("\nShort sequence features:")
        for (index, value) in shortFeatures.enumerated() {
            print("  [\(index)] \(schema.features[index].path): \(value)")
        }
        
        print("\nLong sequence features:")
        for (index, value) in longFeatures.enumerated() {
            print("  [\(index)] \(schema.features[index].path): \(value)")
        }
        
        // Verify that sequence.elements.0 in short sequence corresponds to the first element (10)
        if let elements0Index = schema.features.firstIndex(where: { $0.path == "sequence.elements.0.choice" }) {
            #expect(shortFeatures[elements0Index] == "10", "sequence.elements.0 should be 10 for short sequence")
            #expect(longFeatures[elements0Index] == "100", "sequence.elements.0 should be 100 for long sequence")
        }
        
        // Verify that sequence.elements.1 in short sequence corresponds to the second element (20)
        if let elements1Index = schema.features.firstIndex(where: { $0.path == "sequence.elements.1.choice" }) {
            #expect(shortFeatures[elements1Index] == "20", "sequence.elements.1 should be 20 for short sequence")
            #expect(longFeatures[elements1Index] == "200", "sequence.elements.1 should be 200 for long sequence")
        }
        
        // Verify that sequence.elements.2 in short sequence should be "?" (missing)
        if let elements2Index = schema.features.firstIndex(where: { $0.path == "sequence.elements.2.choice" }) {
            #expect(shortFeatures[elements2Index] == "?", "sequence.elements.2 should be ? for short sequence")
            #expect(longFeatures[elements2Index] == "300", "sequence.elements.2 should be 300 for long sequence")
        }
        
        // Verify that sequence.elements.3 in short sequence should be "?" (missing)
        if let elements3Index = schema.features.firstIndex(where: { $0.path == "sequence.elements.3.choice" }) {
            #expect(shortFeatures[elements3Index] == "?", "sequence.elements.3 should be ? for short sequence")
            #expect(longFeatures[elements3Index] == "400", "sequence.elements.3 should be 400 for long sequence")
        }
    }
}
