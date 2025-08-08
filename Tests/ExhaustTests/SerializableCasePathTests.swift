//
//  SerializableCasePathTests.swift
//  ExhaustTests
//
//  Created by Chris Kolbu on 8/8/2025.
//

import Testing
@testable import Exhaust

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
}