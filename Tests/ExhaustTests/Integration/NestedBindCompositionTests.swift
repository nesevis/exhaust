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
