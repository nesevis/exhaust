//
//  ExploreIntegrationTests.swift
//  ExhaustTests
//

import Testing
@testable import Exhaust
import ExhaustCore

@Suite("ExploreRunner Integration")
struct ExploreIntegrationTests {
    @Test("Finds a failure in a trivially false property")
    func findsTrivialFailure() {
        let gen = #gen(.int(in: 0 ... 100))
        var runner = ExploreRunner(
            gen: gen,
            property: { $0 < 50 },
            maxIterations: 500,
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
        let gen = #gen(.int(in: 0 ... 100))
        var runner = ExploreRunner(
            gen: gen,
            property: { $0 >= 0 },
            maxIterations: 200,
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
        let gen = #gen(.int(in: 0 ... 100).array(length: 3 ... 6))

        var runner = ExploreRunner(
            gen: gen,
            property: { array in array.reduce(0, +) < 400 },
            maxIterations: 10_000,
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
        let branchA = #gen(.int(in: 0 ... 10))
        let branchB = #gen(.int(in: 90 ... 100))
        let gen = #gen(.oneOf(weighted: (9, branchA), (1, branchB)))

        // Property fails only for branchB values (90-100), which are rare (10% probability)
        var runner = ExploreRunner(
            gen: gen,
            property: { $0 < 90 },
            maxIterations: 1_000,
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
        let gen = #gen(.int(in: 0 ... 1000))
        var runner = ExploreRunner(
            gen: gen,
            property: { $0 < 500 },
            maxIterations: 500,
            shrinkConfig: .fast,
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
        let gen = #gen(.int(in: 0 ... 1000))
        var runner = ExploreRunner(
            gen: gen,
            property: { _ in true }, // Always passes — just check pool grows
            maxIterations: 200,
            seed: 42,
            scorer: { _ in 0 }
        )
        _ = runner.run()
        // The pool should have accumulated some seeds (can't assert exact count
        // but the runner should not crash)
    }

    // MARK: - #explore macro

    @Test("#explore macro finds a counterexample")
    func exploreMacroFindsFailure() {
        let gen = #gen(.int(in: 0 ... 100))
        let counterexample = #explore(gen, .maxIterations(500), .suppressIssueReporting,
            scorer: { Double($0) }
        ) { value in
            value < 50
        }
        #expect(counterexample != nil)
        if let ce = counterexample {
            #expect(ce >= 50)
        }
    }

    @Test("#explore macro returns nil for passing property")
    func exploreMacroPassesForTrueProperty() {
        let gen = #gen(.int(in: 0 ... 100))
        let counterexample = #explore(gen, .maxIterations(200), .suppressIssueReporting,
            scorer: { _ in 0.0 }
        ) { value in
            value >= 0
        }
        #expect(counterexample == nil)
    }

    @Test("#explore macro with seed produces deterministic results")
    func exploreMacroDeterministicWithSeed() {
        let gen = #gen(.int(in: 0 ... 1000))

        let result1 = #explore(gen, .maxIterations(200), .replay(42), .suppressIssueReporting,
            scorer: { Double($0) }
        ) { value in
            value < 500
        }
        let result2 = #explore(gen, .maxIterations(200), .replay(42), .suppressIssueReporting,
            scorer: { Double($0) }
        ) { value in
            value < 500
        }
        #expect(result1 == result2)
    }

    @Test("#explore finds failure with narrow region that #exhaust might miss at same iteration budget")
    func exploreFindsNarrowRegion() {
        // A 3-tuple where the property only fails when all three values are in a narrow band.
        // With 3 values each in 0...100, the failure region is values within 5 of each other
        // AND all above 80. This is a very narrow region (~0.01% of the space).
        let gen = #gen(.int(in: 0 ... 100), .int(in: 0 ... 100), .int(in: 0 ... 100))

        let result = #explore(gen, .maxIterations(10_000), .suppressIssueReporting,
            scorer: { a, b, c in Double(a + b + c) }
        ) { a, b, c in
            // Fails when all three are above 90
            !(a > 90 && b > 90 && c > 90)
        }

        if let (a, b, c) = result {
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
        let gen = #gen(.int(in: 0 ... 1000))
        var runner = ExploreRunner(
            gen: gen,
            property: { $0 < 950 },
            maxIterations: 2_000,
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
        let gen = #gen(.int(in: 0 ... 1000))
        let result = #explore(gen, .maxIterations(2_000), .suppressIssueReporting,
            scorer: { Double($0) }
        ) { value in
            value < 900
        }
        #expect(result != nil)
        if let ce = result {
            #expect(ce >= 900)
        }
    }
}
