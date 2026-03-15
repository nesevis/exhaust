//
//  ReplayDeterminismTests.swift
//  ExhaustTests
//
//  Tests for replay determinism functionality ensuring that identical
//  recipes produce identical results across multiple test runs.
//

import ExhaustCore
import Testing
@testable import Exhaust

@Suite("Replay Determinism")
struct ReplayDeterminismTests {
    @Test("Replay produces identical results with same recipe")
    func replayDeterminism() throws {
        let gen = #gen(.string(), .uint(), .int())

        // Generate initial value
        var iterator = ValueInterpreter(gen)
        let initial = try iterator.next()!

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
    func recipeSerializationDeterminism() throws {
        let gen = #gen(.int(in: 1 ... 1000))

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
    func complexStructureReplay() throws {
        struct Person: Equatable {
            let name: String
            let age: UInt
            let scores: [Int]
        }

        let personGen = #gen(.string(), .uint(), .int().array(length: 1 ... 5)) { name, age, scores in
            Person(name: name, age: age, scores: scores)
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
    func arrayReplayOrder() throws {
        let gen = #gen(.string()).array(length: 3 ... 7)

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
