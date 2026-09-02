import Exhaust
import Testing

@Suite("anyNonNil public API")
struct AnyNonNilCombinatorTests {
    @Test("always: produces a value from a producing arm on every run")
    func alwaysProducesValues() {
        let gen = #gen(.anyNonNil(
            always: (1, .just(nil)),
            (1, .int(in: 1 ... 10).mapped(forward: { Optional($0) }, backward: { $0 ?? 0 }))
        ))
        #exhaust(gen, .replay(.numeric(42))) { value in
            (1 ... 10).contains(value)
        }
    }

    @Test("always: accepts an array of arms")
    func alwaysAcceptsArray() {
        let arms: [(Int, ReflectiveGenerator<Int?>)] = [
            (1, .just(nil)),
            (1, .just(3)),
        ]
        let gen = #gen(.anyNonNil(always: arms))
        #exhaust(gen, .replay(.numeric(42))) { value in
            value == 3
        }
    }

    @Test("unlabelled form yields nil only when every arm withdraws")
    func failableYieldsNilOnExhaustion() {
        let partial = #gen(.int(in: 0 ... 9)).map { $0.isMultiple(of: 3) ? $0 : nil }
        let gen = #gen(.anyNonNil((1, partial)))
        #exhaust(gen, .replay(.numeric(42))) { value in
            value == nil || value!.isMultiple(of: 3)
        }
    }

    @Test("unlabelled form prefers a producing arm over absence")
    func failablePrefersProducingArm() {
        let gen = #gen(.anyNonNil((1, .just(Int?.none)), (1, .just(4))))
        #exhaust(gen, .budget(.custom(screening: 0, sampling: 200)), .replay(.numeric(42))) { value in
            value == 4
        }
    }

    @Test("always: exhaustion records an issue at the call site")
    func alwaysExhaustionRecordsIssue() {
        let gen = #gen(.anyNonNil(always: (1, .just(Int?.none)), (1, .just(Int?.none))))
        withKnownIssue("every arm withdraws, so the node reports exhaustion") {
            #exhaust(gen, .replay(.numeric(42))) { _ in
                true
            }
        }
    }

    @Test("Reflection support follows the arms")
    func reflectivityFollowsArms() {
        let reflective = #gen(.anyNonNil(
            always: (1, .int(in: 1 ... 10).mapped(forward: { Optional($0) }, backward: { $0 ?? 0 }))
        ))
        let forwardOnly = #gen(.anyNonNil(
            always: (1, .int(in: 1 ... 10).map { Optional($0) })
        ))
        #expect(reflective.isReflective)
        #expect(forwardOnly.isReflective == false)
    }
}
