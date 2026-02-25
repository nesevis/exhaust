//
//  GenerateMacroIntegrationTests.swift
//  ExhaustTests
//
//  Runtime integration tests verifying that generators created via the
//  #gen macro produce working backward mappings for reflection.
//

import Testing
@testable import Exhaust

@Suite("#gen macro reflection")
struct GenerateMacroIntegrationTests {

    private struct Person: Equatable {
        var name: String
        var age: Int
    }

    private struct Coordinate: Equatable {
        var x: Int
        var y: Int
        var z: Int
    }

    // MARK: - Two-generator bidirectional

    @Test("Two-generator #gen can be reflected")
    func twoGeneratorReflection() throws {
        let nameGen = String.arbitrary
        let ageGen = Gen.choose(in: Int(0) ... 120)
        let personGen = #gen(nameGen, ageGen) { name, age in
            Person(name: name, age: age)
        }

        let target = Person(name: "Alice", age: 30)
        let tree = try #require(try Interpreters.reflect(personGen, with: target))

        let sequence = ChoiceSequence(tree)
        let materialized = try #require(
            try Interpreters.materialize(personGen, with: tree, using: sequence)
        )
        #expect(materialized == target)
    }
    
    @Test("Enum case generator is reflected")
    func enumCaseReflection() throws {
        enum Pet: Equatable {
            case cat(Int)
            case dog(Int, String)
        }
        let catGen = #gen(.int()) { Pet.cat($0) }
        let dogGen = #gen(.int(), .ascii()) { Pet.dog($0, $1) }
        let petGen = Gen.pick(choices: [(1, catGen), (1, dogGen)])
        let target = Pet.dog(13, "Buddy")

        let tree = try #require(try Interpreters.reflect(petGen, with: target))
        let replay = try #require(try Interpreters.replay(petGen, using: tree))
        #expect(replay == target)
    }

    // MARK: - Three-generator bidirectional

    @Test("Three-generator #gen can be reflected")
    func threeGeneratorReflection() throws {
        let xGen = Gen.choose(in: Int(-100) ... 100)
        let yGen = Gen.choose(in: Int(-100) ... 100)
        let zGen = Gen.choose(in: Int(-100) ... 100)
        let coordGen = #gen(xGen, yGen, zGen) { x, y, z in
            Coordinate(x: x, y: y, z: z)
        }

        let target = Coordinate(x: 42, y: -7, z: 99)
        let tree = try #require(try Interpreters.reflect(coordGen, with: target))

        let sequence = ChoiceSequence(tree)
        let materialized = try #require(
            try Interpreters.materialize(coordGen, with: tree, using: sequence)
        )
        #expect(materialized == target)
    }

    // MARK: - Round-trip: generate → reflect → materialize

    @Test("Generated values round-trip through reflection")
    func generationReflectionRoundTrip() throws {
        let nameGen = String.arbitrary
        let ageGen = Gen.choose(in: Int(0) ... 120)
        let personGen = #gen(nameGen, ageGen) { name, age in
            Person(name: name, age: age)
        }

        var iterator = ValueAndChoiceTreeInterpreter(personGen, seed: 7, maxRuns: 10)
        while let (generated, _) = iterator.next() {
            let reflectedTree = try #require(try Interpreters.reflect(personGen, with: generated))
            let sequence = ChoiceSequence(reflectedTree)
            let roundTripped = try #require(
                try Interpreters.materialize(personGen, with: reflectedTree, using: sequence)
            )
            #expect(roundTripped == generated)
        }
    }

    // MARK: - Shorthand parameters bidirectional

    @Test("Shorthand parameters round-trip through reflection")
    func shorthandParametersRoundTrip() throws {
        let nameGen = String.arbitrary
        let ageGen = Gen.choose(in: Int(0) ... 120)
        let personGen = #gen(nameGen, ageGen) { Person(name: $0, age: $1) }

        let target = Person(name: "Bob", age: 25)
        let tree = try #require(try Interpreters.reflect(personGen, with: target))

        let sequence = ChoiceSequence(tree)
        let materialized = try #require(
            try Interpreters.materialize(personGen, with: tree, using: sequence)
        )
        #expect(materialized == target)
    }

    // MARK: - Reflect → shrink

    @Test("#gen'd generator supports reflect then shrink")
    func reflectThenShrink() throws {
        let nameGen = String.arbitrary
        let ageGen = Gen.choose(in: Int(0) ... 1000)
        let personGen = #gen(nameGen, ageGen) { name, age in
            Person(name: name, age: age)
        }

        let failing = Person(name: "zqmfkwvxl", age: 500)
        let tree = try #require(try Interpreters.reflect(personGen, with: failing))

        let property: (Person) -> Bool = { $0.age < 10 }
        #expect(property(failing) == false)

        let (_, shrunk) = try #require(
            try Interpreters.reduce(gen: personGen, tree: tree, config: .fast, property: property)
        )
        #expect(property(shrunk) == false)
        #expect(shrunk.age <= failing.age)
    }
}
