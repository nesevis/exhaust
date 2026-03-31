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
        guard case let .success(materialized, _, _) = Materializer.materialize(personGen, prefix: sequence, mode: .exact, fallbackTree: tree) else {
            Issue.record("Expected .success")
            return
        }
        #expect(materialized == target)
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
        guard case let .success(materialized, _, _) = Materializer.materialize(coordGen, prefix: sequence, mode: .exact, fallbackTree: tree) else {
            Issue.record("Expected .success")
            return
        }
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
            guard case let .success(roundTripped, _, _) = Materializer.materialize(personGen, prefix: sequence, mode: .exact, fallbackTree: reflectedTree) else {
                Issue.record("Expected .success")
                continue
            }
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
        guard case let .success(materialized, _, _) = Materializer.materialize(personGen, prefix: sequence, mode: .exact, fallbackTree: tree) else {
            Issue.record("Expected .success")
            return
        }
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
            try Interpreters.bonsaiReduce(gen: personGen, tree: tree, config: .fast, property: property)
        )
        #expect(property(shrunk) == false)
        #expect(shrunk.age <= failing.age)
    }
}
