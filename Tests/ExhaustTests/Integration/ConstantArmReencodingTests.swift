import Exhaust
import Testing

@Suite("Constant arm re-encoding")
struct ConstantArmReencodingTests {
    @Test("A constant arm reduces through a sibling arm that can express a smaller failing value")
    func constantReducesThroughSibling() throws {
        let gen = #gen(.oneOf(.string(), .just("xyzzy-plover")))
        for seed in UInt64(1) ... 8 {
            let counterexample = #exhaust(
                gen,
                .replay(.numeric(seed)),
                .budget(.custom(screening: 0, sampling: 200)),
                .suppress(.issueReporting)
            ) { text in
                text.contains("xyzzy") == false
            }
            #expect(try #require(counterexample) == "xyzzy")
        }
    }

    @Test("A constant stays when only its own value fails")
    func constantStaysWhenOnlyItFails() throws {
        let gen = #gen(.oneOf(.string(), .just("xyzzy-plover")))
        for seed in UInt64(1) ... 8 {
            let counterexample = #exhaust(
                gen,
                .replay(.numeric(seed)),
                .budget(.custom(screening: 0, sampling: 200)),
                .suppress(.issueReporting)
            ) { text in
                text != "xyzzy-plover"
            }
            #expect(try #require(counterexample) == "xyzzy-plover")
        }
    }

    @Test("A constant declared before its sibling reduces through the sibling")
    func constantDeclaredFirstReducesThroughSibling() throws {
        let gen = #gen(.oneOf(.just("xyzzy-plover"), .string()))
        for seed in UInt64(1) ... 8 {
            let counterexample = #exhaust(
                gen,
                .replay(.numeric(seed)),
                .budget(.custom(screening: 0, sampling: 200)),
                .suppress(.issueReporting)
            ) { text in
                text.contains("xyzzy") == false
            }
            #expect(try #require(counterexample) == "xyzzy")
        }
    }

    @Test("A scalar constant reduces to the smallest failing value of its sibling arm", arguments: [3, 500])
    func scalarConstantReducesThroughSibling(threshold: Int) throws {
        let gen = #gen(.oneOf(weighted: (1, .int(in: 0 ... 1000)), (1000, .just(500))))
        for seed in UInt64(1) ... 8 {
            let counterexample = #exhaust(
                gen,
                .replay(.numeric(seed)),
                .budget(.custom(screening: 0, sampling: 200)),
                .suppress(.issueReporting)
            ) { value in
                value < threshold
            }
            #expect(try #require(counterexample) == threshold)
        }
    }

    @Test("An absent optional stays absent")
    func absentOptionalStaysAbsent() throws {
        let gen = #gen(.int(in: 0 ... 100).optional())
        for seed in UInt64(1) ... 8 {
            let counterexample = #exhaust(
                gen,
                .replay(.numeric(seed)),
                .budget(.custom(screening: 0, sampling: 200)),
                .suppress(.issueReporting)
            ) { value in
                value != nil
            }
            #expect(try #require(counterexample) == nil)
        }
    }

    @Test("Array elements holding a constant still reduce to it")
    func arrayElementsReduceToConstant() throws {
        let element = #gen(.oneOf(.string(), .just("x")))
        let gen = #gen(.array(element, length: 1 ... 5))
        for seed in UInt64(1) ... 8 {
            let counterexample = #exhaust(
                gen,
                .replay(.numeric(seed)),
                .budget(.custom(screening: 0, sampling: 200)),
                .suppress(.issueReporting)
            ) { values in
                values.contains("x") == false
            }
            #expect(try #require(counterexample) == ["x"])
        }
    }
}
