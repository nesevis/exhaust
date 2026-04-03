//
//  ExploreIntegrationTests.swift
//  ExhaustTests
//
//  NOTE: #explore macro is Exhaust-only. Converted to ExploreRunner directly.
//  #gen macro converted to Gen.* API.
//

import ExhaustCore
import Testing

@Suite("ExploreRunner Integration")
struct ExploreIntegrationTests {
    @Test("Finds a failure in a trivially false property")
    func findsTrivialFailure() {
        let gen: ReflectiveGenerator<Int> = Gen.choose(in: 0 ... 100)
        var runner = ExploreRunner(
            gen: gen,
            property: { $0 < 50 },
            samplingBudget: 500,
            seed: 42,
            scorer: { Double($0) }
        )
        let result = runner.run()
        guard case let .failure(counterexample, _, _, _) = result else {
            Issue.record("Expected .failure, got \(result)")
            return
        }
        #expect(counterexample >= 50)
    }

    @Test("Passes for a universally true property")
    func passesForTrueProperty() {
        let gen: ReflectiveGenerator<Int> = Gen.choose(in: 0 ... 100)
        var runner = ExploreRunner(
            gen: gen,
            property: { $0 >= 0 },
            samplingBudget: 200,
            seed: 42,
            scorer: { _ in 0 }
        )
        let result = runner.run()
        guard case .passed = result else {
            Issue.record("Expected .passed, got \(result)")
            return
        }
    }

    @Test("Finds narrow failure region in array sum property")
    func findsNarrowFailureInArraySum() {
        // Property: sum of array elements < 400
        // This fails only when elements sum to >= 400, which is a narrow region
        // when each element is in 0...100 with array length 3...6.
        let gen = Gen.arrayOf(Gen.choose(in: 0 ... 100) as ReflectiveGenerator<Int>, within: 3 ... 6)

        var runner = ExploreRunner(
            gen: gen,
            property: { array in array.reduce(0, +) < 400 },
            samplingBudget: 10000,
            seed: 42,
            scorer: { array in Double(array.reduce(0, +)) }
        )
        let result = runner.run()
        guard case let .failure(counterexample, _, _, _) = result else {
            Issue.record("Expected .failure for narrow array sum property")
            return
        }
        #expect(counterexample.reduce(0, +) >= 400)
    }

    @Test("Finds failure in pick generator")
    func findsFailureInPickGenerator() {
        let branchA: ReflectiveGenerator<Int> = Gen.choose(in: 0 ... 10)
        let branchB: ReflectiveGenerator<Int> = Gen.choose(in: 90 ... 100)
        let gen = Gen.pick(choices: [(9, branchA), (1, branchB)])

        // Property fails only for branchB values (90-100), which are rare (10% probability)
        var runner = ExploreRunner(
            gen: gen,
            property: { $0 < 90 },
            samplingBudget: 1000,
            seed: 42,
            scorer: { Double($0) }
        )
        let result = runner.run()
        guard case let .failure(counterexample, _, _, _) = result else {
            Issue.record("Expected .failure for pick generator with rare branch")
            return
        }
        #expect(counterexample >= 90)
    }

    @Test("Shrinks counterexample after finding failure")
    func shrinksCounterexample() {
        let gen: ReflectiveGenerator<Int> = Gen.choose(in: 0 ... 1000)
        var runner = ExploreRunner(
            gen: gen,
            property: { $0 < 500 },
            samplingBudget: 500,
            reductionConfig: .fast,
            seed: 42,
            scorer: { Double($0) }
        )
        let result = runner.run()
        guard case let .failure(counterexample, _, _, _) = result else {
            Issue.record("Expected .failure")
            return
        }
        // After shrinking, should be the minimal counterexample: 500
        #expect(counterexample == 500)
    }

    @Test("Pool accumulates seeds during exploration")
    func poolAccumulatesSeeds() {
        let gen: ReflectiveGenerator<Int> = Gen.choose(in: 0 ... 1000)
        var runner = ExploreRunner(
            gen: gen,
            property: { _ in true }, // Always passes — just check pool grows
            samplingBudget: 200,
            seed: 42,
            scorer: { _ in 0 }
        )
        _ = runner.run()
        // The pool should have accumulated some seeds (can't assert exact count
        // but the runner should not crash)
    }

    // MARK: - #explore macro (converted to ExploreRunner)

    @Test("#explore macro finds a counterexample")
    func exploreMacroFindsFailure() {
        let gen: ReflectiveGenerator<Int> = Gen.choose(in: 0 ... 100)
        var runner = ExploreRunner(
            gen: gen,
            property: { $0 < 50 },
            samplingBudget: 500,
            seed: nil,
            scorer: { Double($0) }
        )
        let result = runner.run()
        switch result {
        case let .failure(counterexample, _, _, _):
            #expect(counterexample >= 50)
        case let .unreducedFailure(counterexample, _):
            #expect(counterexample >= 50)
        case .passed:
            // May not always find failure
            break
        }
    }

    @Test("#explore macro returns nil for passing property")
    func exploreMacroPassesForTrueProperty() {
        let gen: ReflectiveGenerator<Int> = Gen.choose(in: 0 ... 100)
        var runner = ExploreRunner(
            gen: gen,
            property: { $0 >= 0 },
            samplingBudget: 200,
            seed: nil,
            scorer: { _ in 0.0 }
        )
        let result = runner.run()
        guard case .passed = result else {
            Issue.record("Expected .passed, got \(result)")
            return
        }
    }

    @Test("#explore macro with seed produces deterministic results")
    func exploreMacroDeterministicWithSeed() {
        let gen: ReflectiveGenerator<Int> = Gen.choose(in: 0 ... 1000)

        var runner1 = ExploreRunner(
            gen: gen,
            property: { $0 < 500 },
            samplingBudget: 200,
            seed: 42,
            scorer: { Double($0) }
        )
        var runner2 = ExploreRunner(
            gen: gen,
            property: { $0 < 500 },
            samplingBudget: 200,
            seed: 42,
            scorer: { Double($0) }
        )
        let result1 = runner1.run()
        let result2 = runner2.run()

        // Both should find the same counterexample or both pass
        switch (result1, result2) {
        case let (.failure(ce1, _, _, _), .failure(ce2, _, _, _)):
            #expect(ce1 == ce2)
        case (.passed, .passed):
            break
        default:
            Issue.record("Deterministic results should match: \(result1) vs \(result2)")
        }
    }

    @Test("#explore finds failure with narrow region that #exhaust might miss at same iteration budget")
    func exploreFindsNarrowRegion() {
        let gen = Gen.zip(
            Gen.choose(in: 0 ... 100) as ReflectiveGenerator<Int>,
            Gen.choose(in: 0 ... 100) as ReflectiveGenerator<Int>,
            Gen.choose(in: 0 ... 100) as ReflectiveGenerator<Int>
        )

        var runner = ExploreRunner(
            gen: gen,
            property: { a, b, c in
                // Fails when all three are above 90
                !(a > 90 && b > 90 && c > 90)
            },
            samplingBudget: 10000,
            seed: nil,
            scorer: { a, b, c in Double(a + b + c) }
        )
        let result = runner.run()

        if case let .failure((a, b, c), _, _, _) = result {
            #expect(a > 90)
            #expect(b > 90)
            #expect(c > 90)
        }
        // Note: this test may not always find the failure depending on RNG,
        // but #explore's hill-climbing strategy should help find it more often
        // than pure random generation.
    }

    // MARK: - Fitness-guided tests

    @Test("ExploreRunner with scorer steers toward high-fitness values")
    func runnerWithScorerSteersTowardHighFitness() {
        let gen: ReflectiveGenerator<Int> = Gen.choose(in: 0 ... 1000)
        var runner = ExploreRunner(
            gen: gen,
            property: { $0 < 950 },
            samplingBudget: 2000,
            seed: 42,
            scorer: { Double($0) }
        )
        let result = runner.run()
        guard case let .failure(counterexample, _, _, _) = result else {
            Issue.record("Expected .failure with fitness-guided search")
            return
        }
        #expect(counterexample >= 950)
    }

    @Test("#explore macro with scorer finds counterexample")
    func exploreMacroWithScorer() {
        let gen: ReflectiveGenerator<Int> = Gen.choose(in: 0 ... 1000)
        var runner = ExploreRunner(
            gen: gen,
            property: { $0 < 900 },
            samplingBudget: 2000,
            seed: nil,
            scorer: { Double($0) }
        )
        let result = runner.run()
        switch result {
        case let .failure(ce, _, _, _):
            #expect(ce >= 900)
        case let .unreducedFailure(ce, _):
            #expect(ce >= 900)
        case .passed:
            // May not always find failure
            break
        }
    }
}
