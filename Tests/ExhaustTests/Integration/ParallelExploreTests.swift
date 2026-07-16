import Exhaust
import Testing

@Suite("Parallel explore", .serialized)
struct ParallelExploreTests {
    private static let budget = ExhaustBudget.custom(screening: 10, sampling: 200)

    @Test("Passing property with .parallelize reaches coverage for all directions")
    func passingPropertyWithParallelReachesCoverageForAllDirections() {
        let gen = #gen(.int(in: 0 ... 100))
        let report = #explore(
            gen,
            directions: [
                ("low", { (value: Int) in value < 30 }),
                ("mid", { (value: Int) in value >= 30 && value <= 70 }),
                ("high", { (value: Int) in value > 70 }),
            ],
            .budget(Self.budget),
            .parallelize,
            .suppress(.all)
        ) { value in
            value >= 0
        }
        #expect(report.result == nil)
        #expect(report.termination == .coverageAchieved)
        for coverage in report.directionCoverage {
            #expect(coverage.isCovered, "Direction '\(coverage.name)' should be covered")
        }
    }

    @Test("Failing property finds and reduces a counterexample")
    func failingPropertyFindsAndReducesACounterexample() {
        let gen = #gen(.int(in: 0 ... 100))
        let report = #explore(
            gen,
            directions: [
                ("low", { (value: Int) in value < 30 }),
                ("high", { (value: Int) in value > 70 }),
            ],
            .budget(Self.budget),
            .parallelize,
            .suppress(.all)
        ) { value in
            value < 50
        }
        #expect(report.result != nil)
        #expect(report.termination == .propertyFailed)
        #expect(report.invocations.reduction > 0)
        #expect(report.propertyInvocations == report.invocations.total)
    }

    @Test("Cancellation stops other lanes early when a failure is found")
    func cancellationStopsOtherLanesEarlyWhenAFailureIsFound() {
        let gen = #gen(.int(in: 0 ... 10000))
        let report = #explore(
            gen,
            directions: [
                ("small", { (value: Int) in value < 100 }),
                ("medium", { (value: Int) in value >= 100 && value < 5000 }),
                ("large", { (value: Int) in value >= 5000 }),
            ],
            .budget(.custom(screening: 100, sampling: 2000)),
            .parallelize,
            .suppress(.all)
        ) { value in
            value < 5
        }
        #expect(report.result != nil)
        let maxPossible = 3 * 2000
        #expect(report.propertyInvocations < maxPossible, "Should stop early, not exhaust all budgets")
        #expect(report.invocations.directedSampling < maxPossible, "Should stop early, not exhaust all directed sampling budgets")
    }

    @Test("Direction coverage stats are populated for each direction")
    func directionCoverageStatsArePopulatedForEachDirection() {
        let gen = #gen(.int(in: 0 ... 100))
        let report = #explore(
            gen,
            directions: [
                ("low", { (value: Int) in value < 50 }),
                ("high", { (value: Int) in value >= 50 }),
            ],
            .budget(Self.budget),
            .parallelize,
            .suppress(.all)
        ) { value in
            value >= 0
        }
        #expect(report.directionCoverage.count == 2)
        for coverage in report.directionCoverage {
            #expect(coverage.hits >= Self.budget.hitsPerDirection)
            #expect(coverage.directedSamplingSamples > 0)
            #expect(coverage.warmup == nil)
        }
    }

    @Test("Co-occurrence matrix is populated across directions")
    func coOccurrenceMatrixIsPopulatedAcrossDirections() {
        let gen = #gen(.int(in: 0 ... 100))
        let report = #explore(
            gen,
            directions: [
                ("low", { (value: Int) in value < 50 }),
                ("high", { (value: Int) in value >= 50 }),
            ],
            .budget(Self.budget),
            .parallelize,
            .suppress(.all)
        ) { value in
            value >= 0
        }
        #expect(report.coOccurrence.totalSampleCount > 0)
        #expect(report.coOccurrence.count(direction: 0, direction: 0) > 0)
        #expect(report.coOccurrence.count(direction: 1, direction: 1) > 0)
    }

    @Test("Single direction falls back to sequential")
    func singleDirectionFallsBackToSequential() {
        let gen = #gen(.int(in: 0 ... 100))
        let report = #explore(
            gen,
            directions: [("any", { (_: Int) in true })],
            .budget(Self.budget),
            .parallelize,
            .suppress(.all)
        ) { value in
            value >= 0
        }
        #expect(report.result == nil)
        #expect(report.termination == .coverageAchieved)
        #expect(report.warmup != nil, "Sequential path runs warm-up")
        #expect((report.warmup?.samples ?? 0) > 0)
    }

    @Test("Directed sampling invocations do not exceed the total directed sampling budget")
    func directedSamplingInvocationsDoNotExceedTheTotalDirectedSamplingBudget() {
        let gen = #gen(.int(in: 0 ... 100))
        let report = #explore(
            gen,
            directions: [
                ("low", { (value: Int) in value < 50 }),
                ("high", { (value: Int) in value >= 50 }),
            ],
            .budget(Self.budget),
            .parallelize,
            .suppress(.all)
        ) { value in
            value >= 0
        }
        let maxBudget = report.directionCoverage.count * Self.budget.maxAttemptsPerDirection
        #expect(report.invocations.warmup == 0)
        #expect(report.invocations.regression == 0)
        #expect(report.invocations.directedSampling <= maxBudget)
        #expect(report.invocations.reduction == 0)
        #expect(report.invocations.diagnostic == 0)
        #expect(report.propertyInvocations == report.invocations.total)
        #expect(report.propertyInvocations <= maxBudget)
    }

    @Test("Cross-direction hits from other lanes are merged into the total")
    func crossDirectionHitsFromOtherLanesAreMergedIntoTheTotal() {
        let gen = #gen(.int(in: 0 ... 100))
        let report = #explore(
            gen,
            directions: [
                ("even", { (value: Int) in value % 2 == 0 }),
                ("small", { (value: Int) in value < 30 }),
            ],
            .budget(.custom(screening: 20, sampling: 400)),
            .parallelize,
            .suppress(.all)
        ) { value in
            value >= 0
        }

        let evenCoverage = report.directionCoverage[0]
        let smallCoverage = report.directionCoverage[1]

        // Each lane targets one direction, but classifies every sample against
        // all directions. The "even" lane (tuned for even numbers) will
        // incidentally produce values < 30, contributing hits to "small", and
        // vice versa. For a passing property, directedSamplingPasses equals the lane's
        // own hits for its target direction (every matching sample passes).
        // If cross-lane hits weren't merged, total hits would equal
        // directedSamplingPasses, which is strictly less than the merged total when the
        // predicates overlap.
        #expect(
            evenCoverage.hits > evenCoverage.directedSamplingPasses,
            "Even direction should have hits from the small lane too (got \(evenCoverage.hits) total vs \(evenCoverage.directedSamplingPasses) own-lane hits)"
        )
        #expect(
            smallCoverage.hits > smallCoverage.directedSamplingPasses,
            "Small direction should have hits from the even lane too (got \(smallCoverage.hits) total vs \(smallCoverage.directedSamplingPasses) own-lane hits)"
        )
    }
}
