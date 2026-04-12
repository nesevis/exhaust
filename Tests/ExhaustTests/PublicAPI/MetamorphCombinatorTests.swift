import Testing
@testable import Exhaust

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
    func determinism() {
        let gen = #gen(.int(in: 0 ... 1000)).metamorph { $0 * 3 }
        let first = #example(gen, count: 50, seed: 99)
        let second = #example(gen, count: 50, seed: 99)
        #expect(first.count == second.count)
        for (a, b) in zip(first, second) {
            #expect(a == b)
        }
    }

    // MARK: - Round-Trip

    @Test("Metamorph generators cannot round-trip through reflection and replay")
    func roundTrip() {
        withKnownIssue {
            #examine(#gen(.int(in: 1 ... 100)).metamorph(
                { $0 * 2 },
                { String($0) }
            ))
        }
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
