import Exhaust
import Testing

@Suite("Unfold Combinator")
struct UnfoldTests {
    @Test("Immediate done produces the seed-derived value")
    func immediateDoneProducesTheSeedDerivedValue() throws {
        let gen = ReflectiveGenerator<Int>.unfold(
            seed: .int(in: 1 ... 10),
            depthRange: 1 ... 5,
            step: { state, _ in
                .just(.done(state * 2))
            },
            finish: { state in state * 2 }
        )

        let values = try #example(gen, count: 20, seed: 42)
        #expect(values.isEmpty == false)
        #expect(values.allSatisfy { $0 >= 2 && $0 <= 20 })
    }

    @Test("Countdown accumulates state across iterations")
    func countdownAccumulatesStateAcrossIterations() throws {
        let gen = ReflectiveGenerator<[Int]>.unfold(
            seed: .just((list: [Int](), counter: 0)),
            depthRange: 1 ... 3,
            step: { state, _ in
                .just(.recurse((
                    list: state.list + [state.counter],
                    counter: state.counter + 1
                )))
            },
            finish: { state in state.list }
        )

        let value = try #example(gen, seed: 42)
        #expect(value == [0, 1, 2])
    }

    @Test("Step can terminate early")
    func stepCanTerminateEarly() throws {
        let gen = ReflectiveGenerator<Int>.unfold(
            seed: .just(0),
            depthRange: 1 ... 100,
            step: { state, _ in
                if state >= 3 {
                    return .just(.done(state))
                }
                return .just(.recurse(state + 1))
            },
            finish: { state in state }
        )

        let value = try #example(gen, seed: 42)
        #expect(value == 3)
    }

    @Test("Random decisions within step produce varied output")
    func randomDecisionsWithinStepProduceVariedOutput() throws {
        let gen = ReflectiveGenerator<[Int]>.unfold(
            seed: .just([Int]()),
            depthRange: 1 ... 5,
            step: { list, _ in
                .int(in: 0 ... 10).map { element in
                    element == 0 ? .done(list) : .recurse(list + [element])
                }
            },
            finish: { list in list }
        )

        let values = try #example(gen, count: 50, seed: 42)
        let lengths = Set(values.map(\.count))
        #expect(lengths.count > 1, "Expected varied list lengths, got \(lengths)")
    }

    @Test("Unfold works with #exhaust for property testing")
    func unfoldWorksWithExhaustForPropertyTesting() {
        let gen = ReflectiveGenerator<[Int]>.unfold(
            seed: .just([Int]()),
            depthRange: 1 ... 5,
            step: { list, _ in
                .bool().map { stop in
                    stop ? .done(list) : .recurse(list + [list.count])
                }
            },
            finish: { list in list }
        )

        let result = #exhaust(
            gen,
            .suppress(.issueReporting),
            .budget(.custom(coverage: 0, sampling: 50))
        ) { list in
            list.count <= 5
        }
        #expect(result == nil, "Lists are capped at maxDepth=5, so count <= 5 always holds")
    }

    @Test("Failing property finds and reduces counterexample")
    func failingPropertyFindsAndReducesCounterexample() {
        let gen = ReflectiveGenerator<[Int]>.unfold(
            seed: .just([Int]()),
            depthRange: 1 ... 10,
            step: { list, _ in
                .int(in: 1 ... 100).map { element in
                    .recurse(list + [element])
                }
            },
            finish: { list in list }
        )

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

    @Test("Deterministic replay with seed")
    func deterministicReplayWithSeed() throws {
        let gen = ReflectiveGenerator<Int>.unfold(
            seed: .int(in: 0 ... 100),
            depthRange: 1 ... 3,
            step: { state, _ in
                .int(in: 0 ... 10).map { delta in
                    .recurse(state + delta)
                }
            },
            finish: { state in state }
        )

        let firstValues = try #example(gen, count: 10, seed: 99)
        let secondValues = try #example(gen, count: 10, seed: 99)
        #expect(firstValues == secondValues)
    }

    @Test("Step is never called with a remaining depth of zero")
    func stepIsNeverCalledWithZeroRemaining() throws {
        let observed = RemainingRecorder()
        let gen = ReflectiveGenerator<Int>.unfold(
            seed: .just(0),
            depthRange: 0 ... 5,
            step: { state, remaining in
                observed.append(remaining)
                return .just(.recurse(state + 1))
            },
            finish: { state in state }
        )

        _ = try #example(gen, count: 50, seed: 42)
        #expect(observed.values.isEmpty == false)
        #expect(observed.values.allSatisfy { $0 >= 1 })
    }

    @Test("Depth range lower bound of zero produces finish(seed)")
    func zeroDepthProducesFinishedSeed() throws {
        let gen = ReflectiveGenerator<Int>.unfold(
            seed: .just(7),
            depthRange: 0 ... 0,
            step: { _, _ in
                Issue.record("step must not run when the drawn depth is 0")
                return .just(.done(-1))
            },
            finish: { state in state * 10 }
        )

        let value = try #example(gen, seed: 42)
        #expect(value == 70)
    }
}

// MARK: - Helpers

/// Collects the `remaining` values a step closure observes. Safe without a lock because `#example` interprets single-threaded.
private final class RemainingRecorder: @unchecked Sendable {
    private(set) var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }
}
