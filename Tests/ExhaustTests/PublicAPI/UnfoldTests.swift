import Testing
@testable import Exhaust
@testable import ExhaustCore

@Suite("Unfold Combinator")
struct UnfoldTests {
    @Test("Immediate done produces the seed-derived value")
    func immediateDone() {
        let gen = ReflectiveGenerator<Int>.unfold(
            seed: .int(in: 1 ... 10),
            maxDepth: 5
        ) { state, _ in
            .just(.done(state * 2))
        }

        var interpreter = ValueInterpreter(gen, seed: 42, maxRuns: 20)
        var values: [Int] = []
        while let value = try? interpreter.next() {
            values.append(value)
        }
        #expect(values.isEmpty == false)
        #expect(values.allSatisfy { $0 >= 2 && $0 <= 20 })
    }

    @Test("Countdown accumulates state across iterations")
    func countdownAccumulation() {
        let gen = ReflectiveGenerator<[Int]>.unfold(
            seed: .just((list: [Int](), counter: 0)),
            maxDepth: 3
        ) { state, remaining in
            if remaining == 0 {
                return .just(.done(state.list))
            }
            return .just(.recurse((
                list: state.list + [state.counter],
                counter: state.counter + 1
            )))
        }

        var interpreter = ValueInterpreter(gen, seed: 42, maxRuns: 1)
        let value = try? interpreter.next()
        #expect(value == [0, 1, 2])
    }

    @Test("maxDepth is respected")
    func maxDepthRespected() {
        let gen = ReflectiveGenerator<Int>.unfold(
            seed: .just(0),
            maxDepth: 4
        ) { state, remaining in
            if remaining == 0 {
                return .just(.done(state))
            }
            return .just(.recurse(state + 1))
        }

        var interpreter = ValueInterpreter(gen, seed: 42, maxRuns: 1)
        let value = try? interpreter.next()
        #expect(value == 4, "Always recurses, so output should equal maxDepth")
    }

    @Test("Step can terminate early")
    func earlyTermination() {
        let gen = ReflectiveGenerator<Int>.unfold(
            seed: .just(0),
            maxDepth: 100
        ) { state, remaining in
            if state >= 3 || remaining == 0 {
                return .just(.done(state))
            }
            return .just(.recurse(state + 1))
        }

        var interpreter = ValueInterpreter(gen, seed: 42, maxRuns: 1)
        let value = try? interpreter.next()
        #expect(value == 3)
    }

    @Test("Random decisions within step produce varied output")
    func randomStepDecisions() {
        let gen = ReflectiveGenerator<[Int]>.unfold(
            seed: .just([Int]()),
            maxDepth: 5
        ) { list, remaining in
            if remaining == 0 {
                return .just(.done(list))
            }
            return .int(in: 0 ... 10).map { element in
                element == 0 ? .done(list) : .recurse(list + [element])
            }
        }

        var interpreter = ValueInterpreter(gen, seed: 42, maxRuns: 50)
        var lengths = Set<Int>()
        while let value = try? interpreter.next() {
            lengths.insert(value.count)
        }
        #expect(lengths.count > 1, "Expected varied list lengths, got \(lengths)")
    }

    @Test("Unfold works with #exhaust for property testing")
    func propertyTestIntegration() {
        let gen = ReflectiveGenerator<[Int]>.unfold(
            seed: .just([Int]()),
            maxDepth: 5
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
            .budget(.custom(coverage: 0, sampling: 50)),
            .randomOnly
        ) { list in
            list.count <= 5
        }
        #expect(result == nil, "Lists are capped at maxDepth=5, so count <= 5 always holds")
    }

    @Test("Failing property finds and reduces counterexample")
    func reductionThroughUnfold() {
        let gen = ReflectiveGenerator<[Int]>.unfold(
            seed: .just([Int]()),
            maxDepth: 10
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
            .budget(.custom(coverage: 0, sampling: 100)),
            .randomOnly
        ) { list in
            list.count < 3
        }
        #expect(result != nil, "Should find a list with count >= 3")
        if let result {
            #expect(result.count >= 3)
        }
    }

    @Test("Deterministic replay with seed")
    func deterministicReplay() {
        let gen = ReflectiveGenerator<Int>.unfold(
            seed: .int(in: 0 ... 100),
            maxDepth: 3
        ) { state, remaining in
            if remaining == 0 {
                return .just(.done(state))
            }
            return .int(in: 0 ... 10).map { delta in
                .recurse(state + delta)
            }
        }

        var firstRun = ValueInterpreter(gen, seed: 99, maxRuns: 10)
        var firstValues: [Int] = []
        while let value = try? firstRun.next() {
            firstValues.append(value)
        }

        var secondRun = ValueInterpreter(gen, seed: 99, maxRuns: 10)
        var secondValues: [Int] = []
        while let value = try? secondRun.next() {
            secondValues.append(value)
        }

        #expect(firstValues == secondValues)
    }
}
