import Exhaust
import Foundation
import Testing

@Suite("Metamorphic Combinator")
struct MetamorphCombinatorTests {
    // MARK: - Single Transform

    @Test("Single transform produces (original, transformed) tuple")
    func singleTransform() {
        #exhaust(#gen(.int(in: 1 ... 100)).metamorph { $0 * 2 }) { original, doubled in
            original >= 1 && original <= 100 && doubled == original * 2
        }
    }

    // MARK: - Multiple Homogeneous Transforms

    @Test("Multiple transforms of the same type produce correct tuple")
    func multipleHomogeneous() {
        let gen = #gen(.int(in: 0 ... 50)).metamorph(
            { $0 + 1 },
            { $0 * 10 },
            { -$0 }
        )
        #exhaust(gen) { original, plusOne, timesTen, negated in
            plusOne == original + 1
                && timesTen == original * 10
                && negated == -original
        }
    }

    // MARK: - Heterogeneous Transforms

    @Test("Heterogeneous transforms produce typed tuple")
    func heterogeneous() {
        let gen = #gen(.string(length: 3 ... 10)).metamorph(
            { $0.uppercased() },
            { $0.count }
        )
        #exhaust(gen) { original, uppercased, count in
            uppercased == original.uppercased() && count == original.count
        }
    }

    @Test("Mixed Int and Bool transforms")
    func mixedIntBool() {
        let gen = #gen(.int(in: -100 ... 100)).metamorph(
            { $0 > 0 },
            { abs($0) }
        )
        #exhaust(gen) { original, isPositive, absolute in
            isPositive == (original > 0) && absolute == abs(original)
        }
    }

    // MARK: - Determinism

    @Test("Same seed produces identical results")
    func determinism() throws {
        let gen = #gen(.int(in: 0 ... 1000))
            .metamorph({ $0 * 3 }, { $0 * 6 }, { $0.description })
        let first = try #example(gen, count: 50, seed: 99)
        let second = try #example(gen, count: 50, seed: 99)
        #expect(first.count == second.count)
        for (a, b) in zip(first, second) {
            #expect(a == b)
        }
    }

    // MARK: - Round-Trip

    @Test("Metamorph generators round-trip through reflection and replay")
    func roundTrip() {
        #expect(#examine(#gen(.int(in: 1 ... 100)).metamorph(
            { $0 * 2 },
            { String($0) }
        )).passed)
    }

    @Test("Metamorph round-trips a composed inner generator")
    func composedInnerGeneratorRoundTrips() {
        struct Pair {
            let first: Int
            let second: Int
        }

        let generator = #gen(
            .int(in: 1 ... 100),
            .int(in: 1 ... 100)
        ) {
            Pair(first: $0, second: $1)
        }.metamorph { pair in
            pair.first + pair.second
        }

        #expect(#examine(generator, .samples(50)).passed)
    }

    @Test("Reflection does not run transforms and replay reconstructs transformed values")
    func reflectionReconstructsTransformedValues() throws {
        final class TransformInvocationCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var storage = 0

            var invocations: Int {
                lock.withLock { storage }
            }

            func increment() {
                lock.withLock { storage += 1 }
            }
        }

        let invocationCounter = TransformInvocationCounter()
        let generator = #gen(.int(in: 1 ... 100)).metamorph(
            { value in
                invocationCounter.increment()
                return value * 2
            },
            { value in
                invocationCounter.increment()
                return String(value)
            }
        )
        let target = (37, 999, "stale")

        let reflectedTree = try #require(
            try Interpreters.reflect(generator.gen, with: target)
        )
        #expect(invocationCounter.invocations == 0)

        let replayed = try #require(
            try Interpreters.replay(generator.gen, using: reflectedTree)
        )

        #expect(invocationCounter.invocations == 2)
        #expect(replayed.0 == 37)
        #expect(replayed.1 == 74)
        #expect(replayed.2 == "37")
    }

    @Test("Reflecting reduction derives transformed values from the original")
    func reflectingReductionUsesOriginal() throws {
        let generator = #gen(.int(in: 1 ... 100)).metamorph(
            { $0 * 2 },
            { String($0) }
        )
        let reduced = try #require(
            #exhaust(
                generator,
                reflecting: (37, 999, "stale"),
                .suppress(.issueReporting)
            ) { _, _, _ in
                false
            }
        )

        #expect(reduced.1 == reduced.0 * 2)
        #expect(reduced.2 == String(reduced.0))
    }

    @Test("Reflection gives mutating transforms independent copies")
    func reflectionUsesIndependentCopies() throws {
        final class Box {
            var value: Int

            init(value: Int) {
                self.value = value
            }
        }

        let generator = #gen(.int(in: 1 ... 100))
            .mapped(
                forward: { Box(value: $0) },
                backward: \.value
            )
            .metamorph(
                { box in
                    box.value += 1
                    return box.value
                },
                { box in
                    box.value *= 2
                    return box.value
                }
            )
        let original = Box(value: 37)
        let target = (original, 999, 999)

        let reflectedTree = try #require(
            try Interpreters.reflect(generator.gen, with: target)
        )
        let replayed = try #require(
            try Interpreters.replay(generator.gen, using: reflectedTree)
        )

        #expect(replayed.0.value == 37)
        #expect(replayed.1 == 38)
        #expect(replayed.2 == 74)
        #expect(original.value == 37)
    }

    // MARK: - Composition with Other Combinators

    @Test("metamorph composes with array")
    func composesWithArray() {
        let gen = #gen(.int(in: 1 ... 10))
            .metamorph { $0 * 2 }
            .array(length: 3)

        #exhaust(gen) { array in
            array.count == 3 && array.allSatisfy { $0.1 == $0.0 * 2 }
        }
    }

    @Test("metamorph composes with filter")
    func composesWithFilter() {
        let gen = #gen(.int(in: 1 ... 100))
            .metamorph { $0 % 2 == 0 }
            .filter { $0.0 > 50 }

        #exhaust(gen) { original, isEven in
            original > 50 && isEven == (original % 2 == 0)
        }
    }
}
