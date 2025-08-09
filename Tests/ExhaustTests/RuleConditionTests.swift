//
//  RuleConditionTests.swift
//  ExhaustTests
//
//  Created by Chris Kolbu on 8/8/2025.
//

import Testing
@testable import Exhaust

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