import ExhaustCore
import Testing

@Suite("ClassificationExploreRunner")
struct ClassificationExploreRunnerTests {
    @Test("Covers all directions for a simple generator with common directions")
    func coversCommonDirections() {
        let gen: ReflectiveGenerator<Int> = Gen.choose(in: 0 ... 100)
        var runner = ClassificationExploreRunner(
            gen: gen,
            property: { _ in true },
            directions: [
                (name: "low", predicate: { $0 < 50 }),
                (name: "high", predicate: { $0 >= 50 }),
            ],
            hitsPerDirection: 10,
            maxAttemptsPerDirection: 200,
            seed: 42
        )
        let result = runner.run()
        #expect(result.termination == .coverageAchieved)
        #expect(result.counterexample == nil)
        for entry in result.directionCoverage {
            #expect(entry.isCovered)
            #expect(entry.hits >= 10)
        }
    }

    @Test("Finds failure during warm-up and reduces")
    func findsFailureDuringWarmup() {
        let gen: ReflectiveGenerator<Int> = Gen.choose(in: 0 ... 100)
        var runner = ClassificationExploreRunner(
            gen: gen,
            property: { $0 < 50 },
            directions: [
                (name: "any", predicate: { _ in true }),
            ],
            hitsPerDirection: 30,
            maxAttemptsPerDirection: 500,
            seed: 42
        )
        let result = runner.run()
        #expect(result.termination == .propertyFailed)
        #expect(result.counterexample != nil)
        if let counterexample = result.counterexample {
            #expect(counterexample >= 50)
        }
    }

    @Test("Finds failure during tuning pass with direction-preserving reduction")
    func findsFailureDuringTuningPass() {
        let gen: ReflectiveGenerator<Int> = Gen.choose(in: 0 ... 1000)
        var runner = ClassificationExploreRunner(
            gen: gen,
            property: { $0 < 950 },
            directions: [
                (name: "high", predicate: { $0 > 900 }),
            ],
            hitsPerDirection: 30,
            maxAttemptsPerDirection: 2000,
            seed: 42
        )
        let result = runner.run()
        #expect(result.termination == .propertyFailed)
        if let counterexample = result.counterexample {
            #expect(counterexample >= 950)
        }
    }

    @Test("Co-occurrence matrix records cross-direction overlap")
    func coOccurrenceTracksOverlap() {
        let gen: ReflectiveGenerator<Int> = Gen.choose(in: 0 ... 100)
        var runner = ClassificationExploreRunner(
            gen: gen,
            property: { _ in true },
            directions: [
                (name: "positive", predicate: { $0 > 0 }),
                (name: "above 30", predicate: { $0 > 30 }),
            ],
            hitsPerDirection: 10,
            maxAttemptsPerDirection: 200,
            seed: 42
        )
        let result = runner.run()
        let overlap = result.coOccurrence.count(direction: 0, direction: 1)
        #expect(overlap > 0)
    }

    @Test("Unmatched samples are tracked")
    func unmatchedSamplesTracked() {
        let gen: ReflectiveGenerator<Int> = Gen.choose(in: 0 ... 100)
        var runner = ClassificationExploreRunner(
            gen: gen,
            property: { _ in true },
            directions: [
                (name: "above 90", predicate: { $0 > 90 }),
            ],
            hitsPerDirection: 5,
            maxAttemptsPerDirection: 500,
            seed: 42
        )
        let result = runner.run()
        #expect(result.coOccurrence.unmatchedCount > 0)
    }

    @Test("Deterministic with same seed")
    func deterministicWithSameSeed() {
        let gen: ReflectiveGenerator<Int> = Gen.choose(in: 0 ... 100)

        var runner1 = ClassificationExploreRunner(
            gen: gen,
            property: { $0 < 80 },
            directions: [
                (name: "low", predicate: { $0 < 30 }),
                (name: "mid", predicate: { $0 >= 30 && $0 < 70 }),
                (name: "high", predicate: { $0 >= 70 }),
            ],
            hitsPerDirection: 10,
            maxAttemptsPerDirection: 300,
            seed: 99
        )
        var runner2 = ClassificationExploreRunner(
            gen: gen,
            property: { $0 < 80 },
            directions: [
                (name: "low", predicate: { $0 < 30 }),
                (name: "mid", predicate: { $0 >= 30 && $0 < 70 }),
                (name: "high", predicate: { $0 >= 70 }),
            ],
            hitsPerDirection: 10,
            maxAttemptsPerDirection: 300,
            seed: 99
        )

        let result1 = runner1.run()
        let result2 = runner2.run()

        #expect(result1.propertyInvocations == result2.propertyInvocations)
        #expect(result1.counterexample == result2.counterexample)
    }

    @Test("Budget exhaustion reported for unreachable direction")
    func budgetExhaustionForUnreachableDirection() {
        let gen: ReflectiveGenerator<Int> = Gen.choose(in: 0 ... 10)
        var runner = ClassificationExploreRunner(
            gen: gen,
            property: { _ in true },
            directions: [
                (name: "always matches", predicate: { _ in true }),
                (name: "never matches", predicate: { _ in false }),
            ],
            hitsPerDirection: 10,
            maxAttemptsPerDirection: 50,
            seed: 42
        )
        let result = runner.run()
        #expect(result.directionCoverage[0].isCovered)
        #expect(result.directionCoverage[1].isCovered == false)
        #expect(result.directionCoverage[1].hits == 0)
    }

    @Test("Warm-up hits count toward direction coverage")
    func warmupHitsCountTowardCoverage() {
        let gen: ReflectiveGenerator<Int> = Gen.choose(in: 0 ... 1)
        var runner = ClassificationExploreRunner(
            gen: gen,
            property: { _ in true },
            directions: [
                (name: "any", predicate: { _ in true }),
            ],
            hitsPerDirection: 10,
            maxAttemptsPerDirection: 200,
            seed: 42
        )
        let result = runner.run()
        #expect(result.directionCoverage[0].warmupHits >= 10)
        #expect(result.directionCoverage[0].tuningPassSamples == 0)
        #expect(result.termination == .coverageAchieved)
    }

    @Test("Incidental coverage from other direction's tuning pass")
    func incidentalCoverage() {
        let gen: ReflectiveGenerator<Int> = Gen.choose(in: 0 ... 100)
        var runner = ClassificationExploreRunner(
            gen: gen,
            property: { _ in true },
            directions: [
                (name: "positive", predicate: { $0 > 0 }),
                (name: "above 20", predicate: { $0 > 20 }),
            ],
            hitsPerDirection: 30,
            maxAttemptsPerDirection: 500,
            seed: 42
        )
        let result = runner.run()
        #expect(result.termination == .coverageAchieved)
        for entry in result.directionCoverage {
            #expect(entry.isCovered)
        }
    }
}
