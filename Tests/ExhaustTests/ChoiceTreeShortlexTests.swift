//
//  ChoiceTreeShortlexTests.swift
//  Exhaust
//
//  Created by Chris Kolbu on 28/7/2025.
//

@testable import Exhaust
import Foundation
import See5
import Testing

@Suite("ChoiceTree flattening/classification tests")
struct choiceTreeClassificationTests {
    @Test("See5 full output parser")
    func testOutputParser() throws {
        let input = """
C5.0 [Release 2.07 GPL Edition]      Mon Aug  4 22:08:35 2025
-------------------------------
    Options:
    Application `/var/folders/9j/9mmq088d5sqbhbhv4rdbg7tc0000gn/T/c50_E139547D-8477-4527-BCA6-545362394E04/data'
    Rule-based classifiers
    Pruning confidence level 25%
Read 51 cases (3 attributes) from /var/folders/9j/9mmq088d5sqbhbhv4rdbg7tc0000gn/T/c50_E139547D-8477-4527-BCA6-545362394E04/data.data
Rules:
Rule 1: (16, lift 3.0)
    pick_d1 = false
    sequence_d1 <= 49
    ->  class pass  [0.944]
Rule 2: (23, lift 1.4)
    pick_d1 = true
    ->  class fail  [0.960]
Rule 3: (17, lift 1.4)
    sequence_d1 > 49
    ->  class fail  [0.947]
Default class: fail
Evaluation on training data (51 cases):
            Rules     
      ----------------
        No      Errors
         3    0( 0.0%)   <<
       (a)   (b)    <-classified as
      ----  ----
        16          (a): class pass
              35    (b): class fail
    Attribute usage:
         76%  pick_d1
         65%  sequence_d1
Time: 0.0 secs
"""
        var inputMutable = input[...]
        let rules = See5Parser.parse(source: &inputMutable)
        print()
    }
    @Test("See5 output rule parser")
    func testRuleParser() throws {
        let input = """
Rule 1: (16, lift 3.0)
    pick_d1 = false
    sequence_d1 <= 49
    ->  class pass  [0.944]
"""
        var inputMutable = input[...]
        let rule = See5Parser.Rule.parse(source: &inputMutable)
        #expect(inputMutable.isEmpty)
        #expect(rule != nil)
        print()
        
    }
    
    @Test("Test merging classifications")
    func testMergingClassifications() async throws {
        typealias SchemaTuple = (label: String, type: String, value: String)
        let gen = Gen.zip(Bool.arbitrary, Int.arbitrary, String.arbitraryAscii)
        var iterator = GeneratorIterator(gen, maxRuns: 200)
        let property: ((Bool, Int, String)) -> Bool = { triple in
            triple.2.count < 50
        }
        let originalStart = Date()
        var startTime = Date()
        var results = [[SchemaTuple]]()
        while let instance = iterator.next() {
            guard let tree = try Interpreters.reflect(gen, with: instance) else {
                continue
            }
            var result = tree.flattenForClassification()
            let valid = property(instance)
            result.append(("valid", "true,false", valid.description))
            results.append(result)
            if valid == false {
                print("Fixing iterator at size. \(instance.2.count)")
                break
            }
        }
        let duration = Date().timeIntervalSince(startTime)
        print("Found a failure after \(duration * 1000)ms and \(results.count) runs")
        startTime = Date()
        
        iterator = GeneratorIterator(gen, maxRuns: 200)
        
        // Run for 500ms or 200 instances
        let paddingStart = Date()
        while Date().timeIntervalSince(paddingStart) < 0.5, let instance = iterator.next() {
            guard let tree = try Interpreters.reflect(gen, with: instance) else {
                continue
            }
            var result = tree.flattenForClassification()
            let valid = property(instance)
//            print(instance.2)
            result.append(("valid", "true,false", valid.description))
            results.append(result)
        }
        
        let duration2 = Date().timeIntervalSince(startTime)
        print("Finished padding out adjacent results after \(duration2 * 1000)ms and \(results.count) total")
        startTime = Date()
        
        let schema = results[0].dropLast()
        let dataSchema = DataSchema(
            attributes: schema.map {
                AttributeDefinition(
                    name: $0.label,
                    type: $0.type.contains(",")
                        ? .discrete(values: $0.type.split(separator: ",").map { String($0 )})
                        : .continuous
                )
            },
            classes: ["pass", "fail"]
        )
        
        let cases = results.map { result in
            LabeledDataCase(values: result.dropLast().map { $0.type == "continuous" ? .continuous($0.value) : .discrete($0.value) }, targetClass: result.last?.value == "true" ? "pass" : "fail")
        }
        let trainingData = TrainingData(cases: cases)
        
        let classifier = try await C50Classifier(schema: dataSchema)
        
        let duration3 = Date().timeIntervalSince(startTime)
        print("Marshaled See5 data after \(duration3 * 1000)ms")
        startTime = Date()
        
        try await classifier.train(data: trainingData, options: .init(algorithm: .rules))
        
        let duration4 = Date().timeIntervalSince(startTime)
        print("Finished training on data after \(duration4 * 1000)ms")
        
        print("Completely finished in \(Date().timeIntervalSince(originalStart) * 1000)ms")
        
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
        // Now we need to modify the ChoiceTree to map the rules.
        
        print("Got rules!")
        
    }
}

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
        
        #expect(important.shortlexLength == 1) // Same as wrapped choice
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
        // The logic here has changed
        let meta = ChoiceMetadata(validRanges: UInt64.bitPatternRanges, strategies: [])
        let choice = ChoiceTree.choice(.unsigned(42), meta)
        let important = ChoiceTree.important(choice)
        let just = ChoiceTree.just("String")
        
        print()
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
        #expect(ab?.cast(type: Double.self) == (-900)...(-45.00000000000001))
        #expect(ba?.cast(type: Double.self) == (-900)...(-45))
    }
}
