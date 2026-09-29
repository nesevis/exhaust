import Exhaust
import Testing

@Suite("Nested bind composition")
struct NestedBindCompositionTests {
    @Test("Two controllers reduce together from every failing start", arguments: twoLevelStarts)
    func twoControllersReduceTogether(first: Int, second: Int) throws {
        let start = NestedBindPayload(
            first: first,
            second: second,
            payload: Array(repeating: 0, count: first * second - 1) + [1]
        )

        let counterexample = #exhaust(
            twoLevelGenerator(),
            reflecting: start,
            .suppress(.all)
        ) { value in
            value.payload.count < 24 || value.payload.contains(1) == false
        }

        let reduced = try #require(counterexample)
        #expect(reduced.first == 6)
        #expect(reduced.second == 4)
        #expect(reduced.payload == Array(repeating: 0, count: 23) + [1])
    }

    @Test("A tail controller whose only shorter value lies inside its range is still found", arguments: singleValueStarts)
    func interiorTailValueIsFound(first: Int, second: Int) throws {
        let start = SingleValuePayload(
            first: first,
            second: second,
            payload: Array(repeating: 0, count: first * singleValueWidth(second) - 1) + [1]
        )

        let counterexample = #exhaust(
            singleValueGenerator(),
            reflecting: start,
            .suppress(.all)
        ) { value in
            value.payload.count < 7 || value.payload.contains(1) == false
        }

        let reduced = try #require(counterexample)
        #expect(reduced.first == 7)
        #expect(reduced.second == 23)
        #expect(reduced.payload == Array(repeating: 0, count: 6) + [1])
    }

    @Test("Three controllers reduce through recursive composition")
    func threeControllersReduceThroughRecursiveComposition() throws {
        let start = ThreeLevelPayload(
            first: 3,
            second: 3,
            third: 3,
            payload: Array(repeating: 0, count: 26) + [1]
        )

        let counterexample = #exhaust(
            threeLevelGenerator(),
            reflecting: start,
            .suppress(.all)
        ) { value in
            value.payload.count < 24 || value.payload.contains(1) == false
        }

        let reduced = try #require(counterexample)
        #expect(reduced.first == 4)
        #expect(reduced.second == 3)
        #expect(reduced.third == 2)
        #expect(reduced.payload == Array(repeating: 0, count: 23) + [1])
    }
}

// MARK: - Helpers

/// Every `(first, second)` the two-level generator can produce whose payload is long enough to fail.
private let twoLevelStarts: [(Int, Int)] = (1 ... 10)
    .flatMap { first in (1 ... first).map { second in (first, second) } }
    .filter { first, second in first * second >= 24 }

/// Starts far from 23: at the reduction target, at the far end of the range, and in between, each with a first value the reducer has to move.
private let singleValueStarts: [(Int, Int)] = [(4, 0), (12, 40), (9, 2)]

private struct SingleValuePayload {
    let first: Int
    let second: Int
    let payload: [Int]
}

private struct NestedBindPayload {
    let first: Int
    let second: Int
    let payload: [Int]
}

private struct ThreeLevelPayload {
    let first: Int
    let second: Int
    let third: Int
    let payload: [Int]
}

private func twoLevelGenerator() -> ReflectiveGenerator<NestedBindPayload> {
    #gen(.int(in: 1 ... 10)).bound(
        forward: { first in
            #gen(.int(in: 1 ... first)).bound(
                forward: { second in
                    #gen(.int(in: 0 ... 1).array(length: first * second))
                        .mapped(
                            forward: {
                                NestedBindPayload(
                                    first: first,
                                    second: second,
                                    payload: $0
                                )
                            },
                            backward: \NestedBindPayload.payload
                        )
                },
                backward: \NestedBindPayload.second
            )
        },
        backward: \NestedBindPayload.first
    )
}

private func threeLevelGenerator() -> ReflectiveGenerator<ThreeLevelPayload> {
    #gen(.int(in: 1 ... 6)).bound(
        forward: { first in
            #gen(.int(in: 1 ... first)).bound(
                forward: { second in
                    #gen(.int(in: 1 ... second)).bound(
                        forward: { third in
                            #gen(.int(in: 0 ... 1).array(length: first * second * third))
                                .mapped(
                                    forward: {
                                        ThreeLevelPayload(
                                            first: first,
                                            second: second,
                                            third: third,
                                            payload: $0
                                        )
                                    },
                                    backward: \ThreeLevelPayload.payload
                                )
                        },
                        backward: \ThreeLevelPayload.third
                    )
                },
                backward: \ThreeLevelPayload.second
            )
        },
        backward: \ThreeLevelPayload.first
    )
}

/// Only the tail value 23 halves the payload, so the shortest payload needs a value that is neither end of the tail's range, nor its reduction target, nor next to most starting values.
private func singleValueWidth(_ second: Int) -> Int {
    second == 23 ? 1 : 2
}

private func singleValueGenerator() -> ReflectiveGenerator<SingleValuePayload> {
    #gen(.int(in: 1 ... 12)).bound(
        forward: { first in
            #gen(.int(in: 0 ... 40)).bound(
                forward: { second in
                    #gen(.int(in: 0 ... 1).array(length: first * singleValueWidth(second)))
                        .mapped(
                            forward: {
                                SingleValuePayload(
                                    first: first,
                                    second: second,
                                    payload: $0
                                )
                            },
                            backward: \SingleValuePayload.payload
                        )
                },
                backward: \SingleValuePayload.second
            )
        },
        backward: \SingleValuePayload.first
    )
}
