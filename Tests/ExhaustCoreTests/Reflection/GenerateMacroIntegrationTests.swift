//
//  GenerateMacroIntegrationTests.swift
//  ExhaustTests
//
//  Runtime integration tests verifying that generators created via Gen.zip
//  and Gen.contramap produce working backward mappings for reflection.
//

import ExhaustCore
import Testing

@Suite("Generator reflection")
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

    @Test("Two-generator zip can be reflected")
    func twoGeneratorReflection() throws {
        let nameGen = stringGen()
        let ageGen = Gen.choose(in: 0 ... 120) as ReflectiveGenerator<Int>
        let personGen = Gen.contramap(
            { (p: Person) -> (String, Int) in (p.name, p.age) },
            Gen.zip(nameGen, ageGen)._map { Person(name: $0, age: $1) }
        )

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
        let catGen = Gen.contramap(
            { (p: Pet) -> Int? in guard case let .cat(n) = p else { return nil }; return n },
            (Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling) as ReflectiveGenerator<Int>)
                ._map { Pet.cat($0) }
        )
        let dogGen = Gen.contramap(
            { (p: Pet) -> (Int, String)? in guard case let .dog(n, s) = p else { return nil }; return (n, s) },
            Gen.zip(
                Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling) as ReflectiveGenerator<Int>,
                asciiStringGen()
            )._map { Pet.dog($0, $1) }
        )
        let petGen = Gen.pick(choices: [(1, catGen), (1, dogGen)])
        let target = Pet.dog(13, "Buddy")

        let tree = try #require(try Interpreters.reflect(petGen, with: target))
        let replay = try #require(try Interpreters.replay(petGen, using: tree))
        #expect(replay == target)
    }

    // MARK: - Three-generator bidirectional

    @Test("Three-generator zip can be reflected")
    func threeGeneratorReflection() throws {
        let xGen = Gen.choose(in: -100 ... 100) as ReflectiveGenerator<Int>
        let yGen = Gen.choose(in: -100 ... 100) as ReflectiveGenerator<Int>
        let zGen = Gen.choose(in: -100 ... 100) as ReflectiveGenerator<Int>
        let coordGen = Gen.contramap(
            { (c: Coordinate) -> (Int, Int, Int) in (c.x, c.y, c.z) },
            Gen.zip(xGen, yGen, zGen)._map { Coordinate(x: $0, y: $1, z: $2) }
        )

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
        let nameGen = stringGen()
        let ageGen = Gen.choose(in: 0 ... 120) as ReflectiveGenerator<Int>
        let personGen = Gen.contramap(
            { (p: Person) -> (String, Int) in (p.name, p.age) },
            Gen.zip(nameGen, ageGen)._map { Person(name: $0, age: $1) }
        )

        var iterator = ValueAndChoiceTreeInterpreter(personGen, seed: 7, maxRuns: 10)
        while let (generated, _) = try iterator.next() {
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
        let nameGen = stringGen()
        let ageGen = Gen.choose(in: 0 ... 120) as ReflectiveGenerator<Int>
        let personGen = Gen.contramap(
            { (p: Person) -> (String, Int) in (p.name, p.age) },
            Gen.zip(nameGen, ageGen)._map { Person(name: $0, age: $1) }
        )

        let target = Person(name: "Bob", age: 25)
        let tree = try #require(try Interpreters.reflect(personGen, with: target))

        let sequence = ChoiceSequence(tree)
        let materialized = try #require(
            try Interpreters.materialize(personGen, with: tree, using: sequence)
        )
        #expect(materialized == target)
    }

    // MARK: - Reflect → shrink

    @Test("Generator supports reflect then shrink")
    func reflectThenShrink() throws {
        let nameGen = stringGen()
        let ageGen = Gen.choose(in: 0 ... 1000) as ReflectiveGenerator<Int>
        let personGen = Gen.contramap(
            { (p: Person) -> (String, Int) in (p.name, p.age) },
            Gen.zip(nameGen, ageGen)._map { Person(name: $0, age: $1) }
        )

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
