import Testing
@testable import Exhaust
@testable import ExhaustCore

@Suite("CGS Derivative Context Through Bind Boundaries")
struct CGSBindBoundaryTests {
    @Test("Pick inside bind with different inner/outer types does not crash CGS")
    func pickInsideTypeMismatchedBind() {
        let gen = ReflectiveGenerator<String>.oneOf(
            .just("hello"),
            .just("world"),
            .just("test")
        ).bind { str in
            .just(str.count)
        }.filter(.choiceGradientSampling) { $0 != 0 }

        let values = #example(gen, count: 50, seed: 42)
        #expect(values.allSatisfy { $0 != 0 })
    }

    @Test("Pick inside nested binds with type changes does not crash CGS")
    func pickInsideNestedBinds() {
        let gen = ReflectiveGenerator<Bool>.oneOf(
            .just(true),
            .just(false)
        ).bind { flag in
            ReflectiveGenerator<Int>.just(flag ? 10 : 1)
        }.bind { count in
            ReflectiveGenerator<String>.just(String(repeating: "x", count: count))
        }.filter(.choiceGradientSampling) { $0.isEmpty == false }

        let values = #example(gen, count: 50, seed: 42)
        #expect(values.allSatisfy { $0.isEmpty == false })
    }

    @Test("Unfold with filter does not crash CGS")
    func unfoldWithFilter() {
        let gen = ReflectiveGenerator<Int>.unfold(
            seed: .just(0),
            maxDepth: 3
        ) { state, remaining in
            if remaining == 0 {
                return .just(.done(state))
            }
            return .oneOf(
                .just(.done(state)),
                .just(.recurse(state + 1))
            )
        }.filter(.choiceGradientSampling) { $0 >= 0 }

        let values = #example(gen, count: 50, seed: 42)
        #expect(values.allSatisfy { $0 >= 0 })
    }

    @Test("CGS tunes picks inside bind toward filter predicate")
    func cgsTunesPicksThroughBind() {
        let gen = ReflectiveGenerator<Int>.oneOf(
            weighted: (1, .int(in: 1 ... 100)),
            (1, .int(in: 901 ... 1000))
        ).bind { inner in
            ReflectiveGenerator<[Int]>.just([inner, inner * 2])
        }.filter(.choiceGradientSampling) { array in
            array.allSatisfy { $0 <= 200 }
        }

        let values = #example(gen, count: 100, seed: 42)
        let allValid = values.allSatisfy { $0.allSatisfy { $0 <= 200 } }
        #expect(allValid, "CGS should steer the inner pick toward values <= 100")
    }
}
