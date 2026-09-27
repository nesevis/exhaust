import Exhaust
import Testing

@Suite("Constant arm re-encoding")
struct ConstantArmReencodingTests {
    @Test("A constant arm reduces through a sibling arm that can express a smaller failing value", arguments: seeds)
    func constantReducesThroughSibling(seed: UInt64) throws {
        let counterexample = reduce(#gen(.oneOf(.string(), .just("exhaust-constant-value"))), seed: seed) { text in
            text.contains("exhaust") == false
        }
        #expect(try #require(counterexample) == "exhaust")
    }

    @Test("A constant stays when only its own value fails", arguments: seeds)
    func constantStaysWhenOnlyItFails(seed: UInt64) throws {
        let counterexample = reduce(#gen(.oneOf(.string(), .just("exhaust-constant-value"))), seed: seed) { text in
            text != "exhaust-constant-value"
        }
        #expect(try #require(counterexample) == "exhaust-constant-value")
    }

    @Test("A constant declared before its sibling reduces through the sibling", arguments: seeds)
    func constantDeclaredFirstReducesThroughSibling(seed: UInt64) throws {
        let counterexample = reduce(#gen(.oneOf(.just("exhaust-constant-value"), .string())), seed: seed) { text in
            text.contains("exhaust") == false
        }
        #expect(try #require(counterexample) == "exhaust")
    }

    @Test("A scalar constant reduces to the smallest failing value of its sibling arm", arguments: [3, 500], seeds)
    func scalarConstantReducesThroughSibling(threshold: Int, seed: UInt64) throws {
        let gen = #gen(.oneOf(weighted: (1, .int(in: 0 ... 1000)), (1000, .just(500))))
        let counterexample = reduce(gen, seed: seed) { value in
            value < threshold
        }
        #expect(try #require(counterexample) == threshold)
    }

    @Test("An absent optional stays absent", arguments: seeds)
    func absentOptionalStaysAbsent(seed: UInt64) throws {
        let counterexample = reduce(#gen(.int(in: 0 ... 100).optional()), seed: seed) { value in
            value != nil
        }
        #expect(try #require(counterexample) == nil)
    }

    @Test("Array elements holding a constant still reduce to it", arguments: seeds)
    func arrayElementsReduceToConstant(seed: UInt64) throws {
        let element = #gen(.oneOf(.string(), .just("x")))
        let counterexample = reduce(#gen(.array(element, length: 1 ... 5)), seed: seed) { values in
            values.contains("x") == false
        }
        #expect(try #require(counterexample) == ["x"])
    }
}

// MARK: - Helpers

private let seeds = UInt64(1) ... 8

/// Replays `seed` with sampling only, so each seed reaches a counterexample through a different initial draw.
private func reduce<Value>(
    _ gen: ReflectiveGenerator<Value>,
    seed: UInt64,
    property: @escaping @Sendable (Value) -> Bool
) -> Value? {
    #exhaust(
        gen,
        .replay(.numeric(seed)),
        .budget(.custom(screening: 0, sampling: 200)),
        .suppress(.issueReporting),
        property: property
    )
}
