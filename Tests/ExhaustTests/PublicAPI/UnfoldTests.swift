import Testing
@testable import Exhaust
@testable import ExhaustCore

@Suite("Unfold Combinator")
struct UnfoldTests {
    @Test
    func `Immediate done produces the seed-derived value`() {
        let gen = ReflectiveGenerator<Int>.unfold(
            seed: .int(in: 1 ... 10),
            depthRange: 1 ... 5
        ) { state, _ in
            .just(.done(state * 2))
        }

        let values = #example(gen, count: 20, seed: 42)
        #expect(values.isEmpty == false)
        #expect(values.allSatisfy { $0 >= 2 && $0 <= 20 })
    }

    @Test
    func `Countdown accumulates state across iterations`() {
        let gen = ReflectiveGenerator<[Int]>.unfold(
            seed: .just((list: [Int](), counter: 0)),
            depthRange: 1 ... 3
        ) { state, remaining in
            if remaining == 0 {
                return .just(.done(state.list))
            }
            return .just(.recurse((
                list: state.list + [state.counter],
                counter: state.counter + 1
            )))
        }

        let value = #example(gen, seed: 42)
        #expect(value == [0, 1, 2])
    }

    @Test
    func `Step can terminate early`() {
        let gen = ReflectiveGenerator<Int>.unfold(
            seed: .just(0),
            depthRange: 1 ... 100
        ) { state, remaining in
            if state >= 3 || remaining == 0 {
                return .just(.done(state))
            }
            return .just(.recurse(state + 1))
        }

        let value = #example(gen, seed: 42)
        #expect(value == 3)
    }

    @Test
    func `Random decisions within step produce varied output`() {
        let gen = ReflectiveGenerator<[Int]>.unfold(
            seed: .just([Int]()),
            depthRange: 1 ... 5
        ) { list, remaining in
            if remaining == 0 {
                return .just(.done(list))
            }
            return .int(in: 0 ... 10).map { element in
                element == 0 ? .done(list) : .recurse(list + [element])
            }
        }

        let values = #example(gen, count: 50, seed: 42)
        let lengths = Set(values.map(\.count))
        #expect(lengths.count > 1, "Expected varied list lengths, got \(lengths)")
    }

    @Test
    func `Unfold works with #exhaust for property testing`() {
        let gen = ReflectiveGenerator<[Int]>.unfold(
            seed: .just([Int]()),
            depthRange: 1 ... 5
        ) { list, remaining in
            if remaining == 0 {
                return .just(.done(list))
            }
            return .bool().map { stop in
                stop ? .done(list) : .recurse(list + [list.count])
            }
        }

        let result = #exhaust(
            gen,
            .suppress(.issueReporting),
            .budget(.custom(coverage: 0, sampling: 50))
        ) { list in
            list.count <= 5
        }
        #expect(result == nil, "Lists are capped at maxDepth=5, so count <= 5 always holds")
    }

    @Test
    func `Failing property finds and reduces counterexample`() {
        let gen = ReflectiveGenerator<[Int]>.unfold(
            seed: .just([Int]()),
            depthRange: 1 ... 10
        ) { list, remaining in
            if remaining == 0 {
                return .just(.done(list))
            }
            return .int(in: 1 ... 100).map { element in
                .recurse(list + [element])
            }
        }

        let result = #exhaust(
            gen,
            .suppress(.issueReporting),
            .budget(.custom(coverage: 0, sampling: 100))
        ) { list in
            list.count < 3
        }
        #expect(result != nil, "Should find a list with count >= 3")
        if let result {
            #expect(result.count >= 3)
        }
    }

    @Test
    func `Deterministic replay with seed`() {
        let gen = ReflectiveGenerator<Int>.unfold(
            seed: .int(in: 0 ... 100),
            depthRange: 1 ... 3
        ) { state, remaining in
            if remaining == 0 {
                return .just(.done(state))
            }
            return .int(in: 0 ... 10).map { delta in
                .recurse(state + delta)
            }
        }

        let firstValues = #example(gen, count: 10, seed: 99)
        let secondValues = #example(gen, count: 10, seed: 99)
        #expect(firstValues == secondValues)
    }
}
