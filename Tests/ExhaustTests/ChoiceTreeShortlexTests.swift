//
//  ChoiceTreeShortlexTests.swift
//  Exhaust
//
//  Created by Chris Kolbu on 28/7/2025.
//

import Testing
@testable import Exhaust

@Suite("ChoiceTree shortlex ordering")
struct ChoiceTreeShortlexTests {
    
    // MARK: - shortlexLength Tests
    
    @Test("Constants have zero length")
    func constantsHaveZeroLength() {
        let just = ChoiceTree.just("String")
        let getSize = ChoiceTree.getSize(42)
        
        #expect(just.shortlexLength == 0)
        #expect(getSize.shortlexLength == 0)
    }
    
    @Test("Choice has length 1")
    func choiceHasLengthOne() {
        let meta = ChoiceMetadata(validRanges: UInt64.bitPatternRanges, strategies: [])
        let choice = ChoiceTree.choice(.unsigned(42), meta)
        
        #expect(choice.shortlexLength == 1)
    }
    
    @Test("Resize has no intrinsic length")
    func resizeHasNoIntrinsicLength() {
        let meta = ChoiceMetadata(validRanges: UInt64.bitPatternRanges, strategies: [])
        let choice = ChoiceTree.choice(.unsigned(42), meta)
        let resize = ChoiceTree.resize(newSize: 10, choices: [choice])
        
        #expect(resize.shortlexLength == 1) // Only the choice contributes
    }
    
    @Test("Sequence length includes length and elements")
    func sequenceLengthIncludesLengthAndElements() {
        let meta = ChoiceMetadata(validRanges: UInt64.bitPatternRanges, strategies: [])
        let choice1 = ChoiceTree.choice(.unsigned(1), meta)
        let choice2 = ChoiceTree.choice(.unsigned(2), meta)
        let sequenceMeta = ChoiceMetadata(validRanges: [0...10], strategies: [])
        let sequence = ChoiceTree.sequence(length: 2, elements: [choice1, choice2], sequenceMeta)
        
        #expect(sequence.shortlexLength == 4) // 2 (length) + 1 + 1 (elements)
    }
    
    @Test("Group and branch add structural complexity")
    func groupAndBranchAddStructuralComplexity() {
        let meta = ChoiceMetadata(validRanges: UInt64.bitPatternRanges, strategies: [])
        let choice = ChoiceTree.choice(.unsigned(42), meta)
        let group = ChoiceTree.group([choice])
        let branch = ChoiceTree.branch(label: 1, children: [choice])
        
        #expect(group.shortlexLength == 2) // 1 (structural) + 1 (choice)
        #expect(branch.shortlexLength == 2) // 1 (structural) + 1 (choice)
    }
    
    @Test("Meta-wrappers don't add length")
    func metaWrappersDoNotAddLength() {
        let meta = ChoiceMetadata(validRanges: UInt64.bitPatternRanges, strategies: [])
        let choice = ChoiceTree.choice(.unsigned(42), meta)
        let important = ChoiceTree.important(choice)
        let selected = ChoiceTree.selected(choice)
        
        #expect(important.shortlexLength == 0) // wrapped choice - 1
        #expect(selected.shortlexLength == 1) // Same as wrapped choice
    }
    
    // MARK: - typeOrder Tests
    
    @Test("Meta-wrappers have negative type order")
    func metaWrappersHaveNegativeTypeOrder() {
        let meta = ChoiceMetadata(validRanges: UInt64.bitPatternRanges, strategies: [])
        let choice = ChoiceTree.choice(.unsigned(42), meta)
        let important = ChoiceTree.important(choice)
        let selected = ChoiceTree.selected(choice)
        let just = ChoiceTree.just("String")
        
        #expect(important.typeOrder == -2)
        #expect(selected.typeOrder == -1)
        #expect(just.typeOrder == 0)
        
        // Important comes before selected
        #expect(important.typeOrder < selected.typeOrder)
        // Meta-wrappers come before constants
        #expect(important.typeOrder < just.typeOrder)
        #expect(selected.typeOrder < just.typeOrder)
    }
    
    // MARK: - shortlexPrecedes Tests
    
    @Test("Shorter trees precede longer ones")
    func shorterTreesPrecedeLongerOnes() {
        let meta = ChoiceMetadata(validRanges: UInt64.bitPatternRanges, strategies: [])
        let shortTree = ChoiceTree.choice(.unsigned(1), meta)
        let longTree = ChoiceTree.group([shortTree, shortTree])
        
        #expect(shortTree.shortlexPrecedes(longTree))
        #expect(!longTree.shortlexPrecedes(shortTree))
    }
    
    @Test("Same length trees use lexicographic ordering")
    func sameLengthTreesUseLexicographicOrdering() {
        let meta = ChoiceMetadata(validRanges: UInt64.bitPatternRanges, strategies: [])
        let choice1 = ChoiceTree.choice(.unsigned(1), meta)
        let choice2 = ChoiceTree.choice(.unsigned(2), meta)
        
        #expect(choice1.shortlexPrecedes(choice2))
        #expect(!choice2.shortlexPrecedes(choice1))
    }
    
    @Test("Different node types use type order")
    func differentNodeTypesUseTypeOrder() {
        let meta = ChoiceMetadata(validRanges: UInt64.bitPatternRanges, strategies: [])
        let choice = ChoiceTree.choice(.unsigned(42), meta)
        let important = ChoiceTree.important(choice)
        let just = ChoiceTree.just("String")
        
        // Important (-2) < Selected (-1) < Just (0) < Choice (2)
        #expect(important.shortlexPrecedes(just))
        #expect(just.shortlexPrecedes(choice))
    }
    
    @Test("Sequences compare by length then elements")
    func sequencesCompareByLengthThenElements() {
        let meta = ChoiceMetadata(validRanges: UInt64.bitPatternRanges, strategies: [])
        let sequenceMeta = ChoiceMetadata(validRanges: [0...10], strategies: [])
        
        let choice1 = ChoiceTree.choice(.unsigned(1), meta)
        let choice2 = ChoiceTree.choice(.unsigned(2), meta)
        
        let shortSequence = ChoiceTree.sequence(length: 1, elements: [choice2], sequenceMeta)
        let longSequence = ChoiceTree.sequence(length: 2, elements: [choice1, choice1], sequenceMeta)
        
        // Shorter sequence wins despite having larger element
        #expect(shortSequence.shortlexPrecedes(longSequence))
        
        // Same length: compare elements
        let sequence1 = ChoiceTree.sequence(length: 2, elements: [choice1, choice2], sequenceMeta)
        let sequence2 = ChoiceTree.sequence(length: 2, elements: [choice2, choice1], sequenceMeta)
        
        #expect(sequence1.shortlexPrecedes(sequence2))
    }
    
    @Test("Branches compare by label then children")
    func branchesCompareByLabelThenChildren() {
        let meta = ChoiceMetadata(validRanges: UInt64.bitPatternRanges, strategies: [])
        let choice1 = ChoiceTree.choice(.unsigned(1), meta)
        let choice2 = ChoiceTree.choice(.unsigned(2), meta)
        
        let branch1 = ChoiceTree.branch(label: 1, children: [choice2])
        let branch2 = ChoiceTree.branch(label: 2, children: [choice1])
        
        // Label 1 < label 2
        #expect(branch1.shortlexPrecedes(branch2))
        
        // Same label: compare children
        let branchA = ChoiceTree.branch(label: 1, children: [choice1])
        let branchB = ChoiceTree.branch(label: 1, children: [choice2])
        
        #expect(branchA.shortlexPrecedes(branchB))
    }
    
    @Test("Important nodes are prioritized in comparison")
    func importantNodesArePrioritizedInComparison() {
        let meta = ChoiceMetadata(validRanges: UInt64.bitPatternRanges, strategies: [])
        let choice1 = ChoiceTree.choice(.unsigned(1), meta)
        let choice2 = ChoiceTree.choice(.unsigned(2), meta)
        
        let normalGroup = ChoiceTree.group([choice2]) // Higher value
        let importantGroup = ChoiceTree.group([ChoiceTree.important(choice1)]) // Lower value but important
        
        // Important nodes get prioritized despite the group having same structural complexity
        #expect(importantGroup.shortlexPrecedes(normalGroup))
    }
    
    @Test("Unsigned range refinements work")
    func testUnsignedRangesWork() throws {
        let f = ChoiceValue.unsigned(45)
        let p = ChoiceValue.unsigned(900)
        let ab = f.refineRange(against: p, direction: .towardsHigherBound)
        let ba = p.refineRange(against: f, direction: .towardsLowerBound)
        #expect(ab == 45...899)
        #expect(ba == 45...900)
    }
    
    @Test("Signed positive range refinements work")
    func testSignedPositiveRangesWork() throws {
        let f = ChoiceValue(Int64(45))
        let p = ChoiceValue(Int64(900))
        let ab = f.refineRange(against: p, direction: .towardsHigherBound)
        let ba = p.refineRange(against: f, direction: .towardsLowerBound)
        #expect(ab?.cast(type: Int64.self) == 45...899)
        #expect(ba?.cast(type: Int64.self) == 45...900)
    }
    
    @Test("Signed negative range refinements work")
    func testSignedNegativeRangesWork() throws {
        let f = ChoiceValue(Int64(-45))
        let p = ChoiceValue(Int64(-900))
        let ab = f.refineRange(against: p, direction: .towardsHigherBound)
        let ba = p.refineRange(against: f, direction: .towardsLowerBound)
        #expect(ab?.cast(type: Int64.self) == (-900)...(-46))
        #expect(ba?.cast(type: Int64.self) == (-900)...(-45))
    }
    
    @Test("Float positive range refinements work")
    func testFloatPositiveRangesWork() throws {
        let f = ChoiceValue(Double(45))
        let p = ChoiceValue(Double(900))
        let ab = f.refineRange(against: p, direction: .towardsHigherBound)
        let ba = p.refineRange(against: f, direction: .towardsLowerBound)
        #expect(ab?.cast(type: Double.self) == 45...899.9999999999999)
        #expect(ba?.cast(type: Double.self) == 45...900)
    }
    
    @Test("Float negative range refinements work")
    func testFloatNegativeRangesWork() throws {
        let f = ChoiceValue(Double(-45))
        let p = ChoiceValue(Double(-900))
        let ab = f.refineRange(against: p, direction: .towardsHigherBound)
        let ba = p.refineRange(against: f, direction: .towardsLowerBound)
        #expect(ab?.cast(type: Double.self) == (-900)...(-46))
        #expect(ba?.cast(type: Double.self) == (-900)...(-45))
    }
}
