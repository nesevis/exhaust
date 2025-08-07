//
//  ReplayDeterminismTests.swift
//  ExhaustTests
//
//  Tests for replay determinism functionality ensuring that identical
//  recipes produce identical results across multiple test runs.
//

import Testing
@testable import Exhaust

@Suite("Replay Determinism")
struct ReplayDeterminismTests {
    
    @Test("Replay produces identical results with same recipe")
    func testReplayDeterminism() throws {
        let gen = Gen.zip(String.arbitrary, UInt.arbitrary, Int.arbitrary)
        
        // Generate initial value
        var iterator = GeneratorIterator(gen)
        let initial = iterator.next()!
        
        // Get recipe for that value
        let recipe = try #require(try Interpreters.reflect(gen, with: initial))
        
        // Replay multiple times and verify identical results
        let replay1 = try #require(try Interpreters.replay(gen, using: recipe))
        let replay2 = try #require(try Interpreters.replay(gen, using: recipe))
        let replay3 = try #require(try Interpreters.replay(gen, using: recipe))
        
        #expect(initial == replay1)
        #expect(replay1 == replay2)
        #expect(replay2 == replay3)
    }
    
    @Test("Recipe serialization preserves determinism")
    func testRecipeSerializationDeterminism() throws {
        let gen = Gen.choose(in: 1...1000)
        
        let value = 742
        let recipe = try #require(try Interpreters.reflect(gen, with: value))
        
        // Replay original recipe
        let replay1 = try #require(try Interpreters.replay(gen, using: recipe))
        
        // Create new recipe from replayed value and replay again
        let newRecipe = try #require(try Interpreters.reflect(gen, with: replay1))
        let replay2 = try #require(try Interpreters.replay(gen, using: newRecipe))
        
        #expect(value == replay1)
        #expect(replay1 == replay2)
    }
    
    @Test("Complex structures replay deterministically")
    func testComplexStructureReplay() throws {
        struct Person: Equatable {
            let name: String
            let age: UInt
            let scores: [Int]
        }
        
        let personGen = Gen.lens(extract: \Person.name, String.arbitrary)
            .bind { name in
                Gen.lens(extract: \Person.age, UInt.arbitrary).bind { age in
                    Gen.lens(extract: \Person.scores, Int.arbitrary.proliferate(with: 1...5)).map { scores in
                        Person(name: name, age: age, scores: scores)
                    }
                }
            }
        
        let person = Person(name: "Alice", age: 25, scores: [90, 85, 92])
        let recipe = try #require(try Interpreters.reflect(personGen, with: person))
        
        // Multiple replays should be identical
        let replay1 = try #require(try Interpreters.replay(personGen, using: recipe))
        let replay2 = try #require(try Interpreters.replay(personGen, using: recipe))
        
        #expect(person == replay1)
        #expect(replay1 == replay2)
    }
    
    @Test("Arrays replay with exact element order")
    func testArrayReplayOrder() throws {
        let gen = String.arbitrary.proliferate(with: 3...7)
        
        let array = ["hello", "world", "test", "array"]
        let recipe = try #require(try Interpreters.reflect(gen, with: array))
        
        // Replay should preserve exact order
        let replayed = try #require(try Interpreters.replay(gen, using: recipe))
        
        #expect(array == replayed)
        #expect(array.count == replayed.count)
        
        // Check element-by-element
        for (original, replayed) in zip(array, replayed) {
            #expect(original == replayed)
        }
    }
}
