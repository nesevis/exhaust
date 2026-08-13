//
//  EachOfGeneratorTests.swift
//  Exhaust
//

import Exhaust
import Testing

@Suite("eachOf generator")
struct EachOfGeneratorTests {
    @Test("Every position stays inside its own domain")
    func everyPositionStaysInsideItsOwnDomain() {
        let generator = #gen(.eachOf(Self.positions) { position in
            .int(in: position.domain)
        })

        #exhaust(generator, .budget(.quick)) { values in
            values.count == Self.positions.count
                && zip(Self.positions, values).allSatisfy { position, value in
                    position.domain.contains(value)
                }
        }
    }

    @Test("An array of generators produces one value from each, in order")
    func arrayOfGeneratorsProducesOneValueFromEach() {
        let generators: [ReflectiveGenerator<Int>] = [.int(in: 0 ... 9), .int(in: 100 ... 109)]

        #exhaust(#gen(.eachOf(generators)), .budget(.quick)) { values in
            values.count == 2
                && (0 ... 9).contains(values[0])
                && (100 ... 109).contains(values[1])
        }
    }

    @Test("Reflection round-trip and replay determinism hold")
    func reflectionRoundTripAndReplayDeterminismHold() {
        let generator = #gen(.eachOf(Self.positions) { position in
            .int(in: position.domain)
        })
        let report = #examine(generator, .samples(50))

        #expect(report.passed)
    }

    @Test("A position held above its floor by the property does not drag the others")
    func positionHeldAboveItsFloorDoesNotDragTheOthers() {
        let generator = #gen(.eachOf(Self.positions) { position in
            .int(in: position.domain)
        })

        // Only position 0 is constrained, and only from 5 upward. Positions 1 and 2 are free to reach their own floors, so an independent search returns each position's minimum failing value rather than one common outcome.
        let reduced = #exhaust(
            generator,
            reflecting: [7, 105, 205],
            .suppress(.issueReporting)
        ) { values in
            values[0] < 5
        }

        #expect(reduced == [5, 100, 200])
    }

    @Test("Constant generators reproduce the input collection")
    func constantGeneratorsReproduceTheInputCollection() throws {
        let letters = ["a", "b", "c"]
        let generator = #gen(.eachOf(letters) { .just($0) })
        let values = try #example(generator, count: 5, seed: 1)

        #expect(values.allSatisfy { $0 == letters })
    }

    @Test("An empty collection produces the empty array")
    func emptyCollectionProducesTheEmptyArray() throws {
        let generator = #gen(.eachOf([Int]()) { _ in .int(in: 0 ... 9) })
        let values = try #example(generator, count: 3, seed: 1)

        let everyValueIsEmpty = values.allSatisfy(\.isEmpty)
        #expect(everyValueIsEmpty)
    }

    @Test("An empty array of generators produces the empty array")
    func emptyArrayOfGeneratorsProducesTheEmptyArray() throws {
        let generators: [ReflectiveGenerator<Int>] = []
        let values = try #example(#gen(.eachOf(generators)), count: 3, seed: 1)

        let everyValueIsEmpty = values.allSatisfy(\.isEmpty)
        #expect(everyValueIsEmpty)
    }
}

// MARK: - Helpers

private extension EachOfGeneratorTests {
    struct Position {
        let domain: ClosedRange<Int>
    }

    static let positions = [
        Position(domain: 0 ... 9),
        Position(domain: 100 ... 109),
        Position(domain: 200 ... 209),
    ]
}
