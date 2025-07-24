//
//  HierarchicalTieredShrinkerTests.swift
//  Exhaust
//
//  Created by Chris Kolbu on 22/7/2025.
//

import Testing
@testable import Exhaust

@Suite("Hierarchical shrinking iterator")
struct HierarchicalTieredShrinkerTests {
    @Test("Fundamental shrinks work")
    func fundamentalShrinksWorks() throws {
        let value = ChoiceValue.unsigned(976)
        let choice = ChoiceTree.choice(value, .init(validRanges: UInt64.bitPatternRanges, strategies: [FundamentalReducerStrategy(direction: .towardsLowerBound)]))
        let iterator = HierarchicalTieredShrinker(choice)
        
        var array: [ChoiceTree?] = []
        while let current = iterator.next() {
            array.append(current)
        }
        let values = array.compactMap { choice in
            if case let .choice(value, _) = choice {
                return value
            }
            return nil
        }
        // Takes 0.25 milliseconds to run averaged over 100 runs
        #expect(value.fundamentalValues == values)
    }
    
    @Test("Test fundamental values for sequences")
    func fundamentalShrinkSequenceWorks() throws {
        let sequenceMeta = ChoiceMetadata(validRanges: [0...3], strategies: [FundamentalReducerStrategy(direction: .towardsLowerBound)])
        let choiceMeta = ChoiceMetadata(validRanges: UInt64.bitPatternRanges, strategies: [FundamentalReducerStrategy(direction: .towardsLowerBound)])
        let values = [
            ChoiceTree.choice(.unsigned(1), choiceMeta),
            ChoiceTree.choice(.unsigned(2), choiceMeta),
            ChoiceTree.choice(.unsigned(3), choiceMeta)
        ]
        let choice = ChoiceTree.sequence(length: UInt64(values.count), elements: values, sequenceMeta)
        let iterator = HierarchicalTieredShrinker(choice)
        
        var array: [ChoiceTree] = []
        while let current = iterator.next() {
            array.append(current)
        }
        #expect(array.count == 12) // Combinatory thing here?
    }
    
    @Test("Test range filtering for sequences")
    func fundamentalShrinkSequenceRangeFilteringWorks() throws {
        let sequenceMeta = ChoiceMetadata(validRanges: [2...3], strategies: [FundamentalReducerStrategy(direction: .towardsLowerBound)])
        let choiceMeta = ChoiceMetadata(validRanges: UInt64.bitPatternRanges, strategies: [FundamentalReducerStrategy(direction: .towardsLowerBound)])
        let values = [
            ChoiceTree.choice(.unsigned(1), choiceMeta),
            ChoiceTree.choice(.unsigned(2), choiceMeta),
            ChoiceTree.choice(.unsigned(3), choiceMeta)
        ]
        let choice = ChoiceTree.sequence(length: UInt64(values.count), elements: values, sequenceMeta)
        let iterator = HierarchicalTieredShrinker(choice)
        
        var array: [ChoiceTree] = []
        while let current = iterator.next() {
            array.append(current)
        }
        #expect(array.isEmpty)
    }
    
    @Test("Test multiple strategies")
    func testMultipleStrategies() throws {
        let sequenceMeta = ChoiceMetadata(validRanges: [0...3], strategies: [FundamentalReducerStrategy(direction: .towardsLowerBound), BoundaryReducerStrategy(direction: .towardsLowerBound)])
        let choiceMeta = ChoiceMetadata(validRanges: UInt64.bitPatternRanges, strategies: [FundamentalReducerStrategy(direction: .towardsLowerBound), BoundaryReducerStrategy(direction: .towardsLowerBound)])
        let values = [
            ChoiceTree.choice(.unsigned(1), choiceMeta),
            ChoiceTree.choice(.unsigned(2), choiceMeta),
            ChoiceTree.choice(.unsigned(3), choiceMeta)
        ]
        let choice = ChoiceTree.sequence(length: UInt64(values.count), elements: values, sequenceMeta)
        let iterator = HierarchicalTieredShrinker(choice)
        
        var array: [ChoiceTree] = []
        while let current = iterator.next() {
            array.append(current)
        }
        #expect(array.count == 17) // Combinatory thing here?
    }
    
    @Test("Test shrinking")
    func testShrinking() throws {
        let generator = UInt64.arbitrary
        let value = UInt64(1337)
        let shrunken = try Interpreters.shrink(value, using: generator, where: { $0 < 1 })
        
        print()
        #expect(shrunken == 1) // Combinatory thing here?
    }
}
