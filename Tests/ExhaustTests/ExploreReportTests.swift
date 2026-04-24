import Testing
@testable import Exhaust

@Suite("ExploreBudget")
struct ExploreBudgetTests {
    @Test("Expedient preset values")
    func expedientPreset() {
        let budget = ExploreBudget.expedient
        #expect(budget.hitsPerDirection == 30)
        #expect(budget.maxAttemptsPerDirection == 300)
    }

    @Test("Expensive preset values")
    func expensivePreset() {
        let budget = ExploreBudget.expensive
        #expect(budget.hitsPerDirection == 100)
        #expect(budget.maxAttemptsPerDirection == 1000)
    }

    @Test("Exorbitant preset values")
    func exorbitantPreset() {
        let budget = ExploreBudget.exorbitant
        #expect(budget.hitsPerDirection == 300)
        #expect(budget.maxAttemptsPerDirection == 3000)
    }

    @Test("Custom budget values")
    func customBudget() {
        let budget = ExploreBudget.custom(hitsPerDirection: 50, maxAttemptsPerDirection: 750)
        #expect(budget.hitsPerDirection == 50)
        #expect(budget.maxAttemptsPerDirection == 750)
    }
}

@Suite("CoOccurrenceMatrix")
struct CoOccurrenceMatrixTests {
    @Test("Empty matrix has zero counts")
    func emptyMatrix() {
        let matrix = CoOccurrenceMatrix(directionCount: 3)
        for indexA in 0 ..< 3 {
            for indexB in 0 ..< 3 {
                #expect(matrix.count(direction: indexA, direction: indexB) == 0)
            }
        }
        #expect(matrix.unmatchedCount == 0)
        #expect(matrix.totalSampleCount == 0)
    }

    @Test("Record hit maintains symmetry")
    func recordHitSymmetry() {
        var matrix = CoOccurrenceMatrix(directionCount: 3)
        matrix.recordHit(direction: 0, direction: 2)
        #expect(matrix.count(direction: 0, direction: 2) == 1)
        #expect(matrix.count(direction: 2, direction: 0) == 1)
        #expect(matrix.count(direction: 0, direction: 1) == 0)
    }

    @Test("Record hit on diagonal does not double count")
    func recordHitDiagonal() {
        var matrix = CoOccurrenceMatrix(directionCount: 2)
        matrix.recordHit(direction: 0, direction: 0)
        #expect(matrix.count(direction: 0, direction: 0) == 1)
    }

    @Test("Record sample with no matching directions increments unmatched")
    func recordUnmatchedSample() {
        var matrix = CoOccurrenceMatrix(directionCount: 2)
        matrix.recordSample(matchingDirections: [])
        #expect(matrix.unmatchedCount == 1)
        #expect(matrix.totalSampleCount == 1)
    }

    @Test("Record sample with single direction increments diagonal only")
    func recordSingleDirectionSample() {
        var matrix = CoOccurrenceMatrix(directionCount: 3)
        matrix.recordSample(matchingDirections: [1])
        #expect(matrix.count(direction: 1, direction: 1) == 1)
        #expect(matrix.count(direction: 0, direction: 0) == 0)
        #expect(matrix.count(direction: 0, direction: 1) == 0)
        #expect(matrix.totalSampleCount == 1)
    }

    @Test("Record sample with multiple directions updates diagonal and off-diagonal")
    func recordMultiDirectionSample() {
        var matrix = CoOccurrenceMatrix(directionCount: 3)
        matrix.recordSample(matchingDirections: [0, 2])
        #expect(matrix.count(direction: 0, direction: 0) == 1)
        #expect(matrix.count(direction: 2, direction: 2) == 1)
        #expect(matrix.count(direction: 0, direction: 2) == 1)
        #expect(matrix.count(direction: 2, direction: 0) == 1)
        #expect(matrix.count(direction: 1, direction: 1) == 0)
    }

    @Test("Total sample count is diagonal sum plus unmatched")
    func totalSampleCount() {
        var matrix = CoOccurrenceMatrix(directionCount: 2)
        matrix.recordSample(matchingDirections: [0])
        matrix.recordSample(matchingDirections: [0, 1])
        matrix.recordSample(matchingDirections: [])
        #expect(matrix.count(direction: 0, direction: 0) == 2)
        #expect(matrix.count(direction: 1, direction: 1) == 1)
        #expect(matrix.unmatchedCount == 1)
        #expect(matrix.totalSampleCount == 4)
    }

    @Test("Entangled pairs detects redundant directions")
    func entangledPairsDetectsRedundancy() {
        var matrix = CoOccurrenceMatrix(directionCount: 2)
        for _ in 0 ..< 100 {
            matrix.recordSample(matchingDirections: [0, 1])
        }
        let pairs = matrix.entangledPairs(threshold: 0.5)
        #expect(pairs.count == 1)
        #expect(pairs[0].directionA == 0)
        #expect(pairs[0].directionB == 1)
    }

    @Test("Entangled pairs returns empty for weakly correlated directions")
    func entangledPairsWeakCorrelation() {
        var matrix = CoOccurrenceMatrix(directionCount: 2)
        for _ in 0 ..< 40 {
            matrix.recordSample(matchingDirections: [0])
        }
        for _ in 0 ..< 40 {
            matrix.recordSample(matchingDirections: [1])
        }
        for _ in 0 ..< 10 {
            matrix.recordSample(matchingDirections: [0, 1])
        }
        for _ in 0 ..< 10 {
            matrix.recordSample(matchingDirections: [])
        }
        let pairs = matrix.entangledPairs(threshold: 0.8)
        #expect(pairs.isEmpty)
    }

    @Test("Infeasible conjunction evidence for zero-overlap pairs")
    func infeasibleConjunctionEvidence() {
        var matrix = CoOccurrenceMatrix(directionCount: 3)
        for _ in 0 ..< 100 {
            matrix.recordSample(matchingDirections: [0])
        }
        for _ in 0 ..< 100 {
            matrix.recordSample(matchingDirections: [1])
        }
        let evidence = matrix.infeasibleConjunctionEvidence(totalWarmupSamples: 200)
        let zeroOverlapPairs = evidence.map { ($0.directionA, $0.directionB) }
        #expect(zeroOverlapPairs.contains { $0.0 == 0 && $0.1 == 1 })
        #expect(zeroOverlapPairs.contains { $0.0 == 0 && $0.1 == 2 })
        #expect(zeroOverlapPairs.contains { $0.0 == 1 && $0.1 == 2 })
        if let bound = evidence.first?.ruleOfThreeUpperBound {
            #expect(bound == 3.0 / 200.0)
        }
    }
}

@Suite("ExploreReport")
struct ExploreReportTests {
    @Test("Report with no failure has nil result")
    func reportWithNoFailure() {
        let report = ExploreReport<Int>(
            result: nil,
            seed: 42,
            directionCoverage: [],
            coOccurrence: CoOccurrenceMatrix(directionCount: 0),
            counterexampleDirections: [],
            propertyInvocations: 100,
            warmupSamples: 100,
            totalMilliseconds: 50.0,
            termination: .coverageAchieved
        )
        #expect(report.result == nil)
        #expect(report.termination == .coverageAchieved)
    }

    @Test("Report with failure has counterexample and direction membership")
    func reportWithFailure() {
        let report = ExploreReport<Int>(
            result: 42,
            seed: 99,
            directionCoverage: [
                DirectionCoverage(
                    name: "positive",
                    hits: 30,
                    tuningPassSamples: 50,
                    tuningPassPasses: 49,
                    tuningPassFailures: 1,
                    warmupHits: 10,
                    isCovered: true,
                    warmupRuleOfThreeBound: 3.0 / 10.0,
                    tuningPassRuleOfThreeBound: nil
                ),
            ],
            coOccurrence: CoOccurrenceMatrix(directionCount: 1),
            counterexampleDirections: [0],
            propertyInvocations: 50,
            warmupSamples: 100,
            totalMilliseconds: 25.0,
            termination: .propertyFailed
        )
        #expect(report.result == 42)
        #expect(report.counterexampleDirections == [0])
        #expect(report.termination == .propertyFailed)
    }
}
