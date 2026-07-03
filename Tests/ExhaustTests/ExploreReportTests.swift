import Testing
@testable import Exhaust

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

    @Test("Total sample count tracks actual samples, not direction hits")
    func totalSampleCount() {
        var matrix = CoOccurrenceMatrix(directionCount: 2)
        matrix.recordSample(matchingDirections: [0])
        matrix.recordSample(matchingDirections: [0, 1])
        matrix.recordSample(matchingDirections: [])
        #expect(matrix.count(direction: 0, direction: 0) == 2)
        #expect(matrix.count(direction: 1, direction: 1) == 1)
        #expect(matrix.unmatchedCount == 1)
        #expect(matrix.totalSampleCount == 3)
    }

    @Test("Entangled pairs detects redundant directions")
    func entangledPairsDetectsRedundancy() {
        var matrix = CoOccurrenceMatrix(directionCount: 2)
        for _ in 0 ..< 90 {
            matrix.recordSample(matchingDirections: [0, 1])
        }
        for _ in 0 ..< 10 {
            matrix.recordSample(matchingDirections: [])
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
            warmup: WarmupStats(samples: 100),
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
                    outcome: .covered,
                    warmup: DirectionWarmup(hits: 10)
                ),
            ],
            coOccurrence: CoOccurrenceMatrix(directionCount: 1),
            counterexampleDirections: [0],
            propertyInvocations: 50,
            warmup: WarmupStats(samples: 100),
            totalMilliseconds: 25.0,
            termination: .propertyFailed
        )
        #expect(report.result == 42)
        #expect(report.counterexampleDirections == [0])
        #expect(report.termination == .propertyFailed)
    }

    @Test("isCovered reflects the outcome case")
    func isCoveredReflectsOutcome() {
        #expect(makeCoverage(outcome: .covered).isCovered)
        #expect(makeCoverage(outcome: .uncovered).isCovered == false)
        #expect(makeCoverage(outcome: .tuningFailed("subdivision failed")).isCovered == false)
    }

    @Test("Warm-up rule-of-three bound derives from hits")
    func warmupBoundDerivesFromHits() {
        #expect(DirectionWarmup(hits: 0).ruleOfThreeBound == nil)
        #expect(DirectionWarmup(hits: 10).ruleOfThreeBound == 0.3)
    }

    @Test("Tuning-pass rule-of-three bound derives from passing samples")
    func tuningBoundDerivesFromPasses() {
        #expect(makeCoverage(outcome: .covered, tuningPassPasses: 0).tuningPassRuleOfThreeBound == nil)
        #expect(makeCoverage(outcome: .covered, tuningPassPasses: 30).tuningPassRuleOfThreeBound == 0.1)
    }
}

// MARK: - Helpers

private func makeCoverage(outcome: DirectionOutcome, tuningPassPasses: Int = 0) -> DirectionCoverage {
    DirectionCoverage(
        name: "direction",
        hits: 0,
        tuningPassSamples: 0,
        tuningPassPasses: tuningPassPasses,
        tuningPassFailures: 0,
        outcome: outcome,
        warmup: nil
    )
}
