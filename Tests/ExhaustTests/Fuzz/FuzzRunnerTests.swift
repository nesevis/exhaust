import ExhaustCore
import ExhaustTestSupport
import Testing
@testable import Exhaust

@Suite("FuzzRunner end-to-end tests with synthetic coverage")
struct FuzzRunnerTests {
    @Test("Attempt-limited run finishes with phase attempts accounted for")
    func attemptAccounting() {
        let runner = FuzzRunner(
            gen: Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
            property: { _ in .pass },
            source: bucketedSource(),
            configuration: FuzzRunnerConfiguration(
                budgetNanoseconds: 60_000_000_000,
                seed: 7,
                attemptLimit: 3000
            )
        )
        let result = runner.run()
        #expect(result.termination == .attemptLimitReached)
        #expect(result.totalAttempts >= 3000)
        #expect(result.screeningAttempts > 0)
        #expect(result.mutationAttempts > 0)
        #expect(result.corpusEntryCount > 0)
        #expect(result.coveredEdgeCount > 0)
        #expect(result.clusters.isEmpty)
    }

    @Test("Phase skipping starts the run directly in the mutation phase")
    func phaseSkipping() {
        let runner = FuzzRunner(
            gen: Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
            property: { _ in .pass },
            source: bucketedSource(),
            configuration: FuzzRunnerConfiguration(
                budgetNanoseconds: 60_000_000_000,
                seed: 7,
                skipScreening: true,
                skipSampling: true,
                attemptLimit: 500
            )
        )
        let result = runner.run()
        #expect(result.screeningAttempts == 0)
        #expect(result.samplingAttempts == 0)
        #expect(result.mutationAttempts >= 500)
        // The empty-corpus fallback sampled fresh values and seeded the corpus.
        #expect(result.corpusEntryCount > 0)
        #expect(result.mutableTierCount > 0)
    }

    @Test("Structurally distinct failures with one symptom form distinct clusters")
    func distinctClusters() {
        // Two disjoint failure regions whose shortlex-minimal failing values differ (41 and 941). Neither region contains the other's minimum, so the reducer's value search cannot walk one into the other — two clusters despite the identical symptom.
        let property: @Sendable (Int) -> FuzzVerdict = { value in
            (value > 40 && value < 60) || value > 940 ? .fail(.returnedFalse) : .pass
        }
        let runner = FuzzRunner(
            gen: Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
            property: property,
            source: bucketedSource(),
            configuration: FuzzRunnerConfiguration(
                budgetNanoseconds: 60_000_000_000,
                seed: 11,
                attemptLimit: 1500
            )
        )
        let result = runner.run()
        #expect(result.clusters.count == 2)

        let descriptions = Set(result.clusters.map(\.reducedDescription))
        #expect(descriptions.contains("41"))
        #expect(descriptions.contains("941"))
        for cluster in result.clusters {
            #expect(cluster.reducedCount >= 1)
            #expect(cluster.instanceCount >= cluster.reducedCount)
        }
    }

    @Test("Cluster inventory is stable across runs with the same seed")
    func seedStableInventory() {
        func clusterForms(seed: UInt64) -> Set<String> {
            let runner = FuzzRunner(
                gen: Gen.choose(in: 0 ... 100 as ClosedRange<Int>),
                property: { value in value == 42 ? .fail(.returnedFalse) : .pass },
                source: bucketedSource(),
                configuration: FuzzRunnerConfiguration(
                    budgetNanoseconds: 60_000_000_000,
                    seed: seed,
                    attemptLimit: 800
                )
            )
            return Set(runner.run().clusters.map(\.reducedDescription))
        }
        // Inventory contents are deterministic under a pinned seed; only Task completion timestamps vary.
        #expect(clusterForms(seed: 3) == clusterForms(seed: 3))
        #expect(clusterForms(seed: 3) == ["42"])
    }

    @Test("Saturated coverage ends the run on plateau and returns unused budget")
    func plateauTermination() {
        // Four reachable edges saturate within a handful of attempts; the mutation-phase plateau window (25% of a 400ms budget) then fires long before the budget ends.
        let source = SyntheticCoverageSource<Int>(edgeCount: 8, edges: { value in
            [value & 0b11]
        })
        let runner = FuzzRunner(
            gen: Gen.choose(in: 0 ... 3 as ClosedRange<Int>),
            property: { _ in .pass },
            source: source,
            configuration: FuzzRunnerConfiguration(
                budgetNanoseconds: 400_000_000,
                seed: 5
            )
        )
        let result = runner.run()
        guard case let .plateau(unusedNanoseconds) = result.termination else {
            Issue.record("Expected plateau termination, got \(result.termination)")
            return
        }
        #expect(unusedNanoseconds > 0)
        #expect(result.elapsedNanoseconds < 400_000_000)
    }

    @Test("Incidence counters saturate: edges hit by many distinct attempts report as neither singletons nor doubletons")
    func incidenceCounterSaturation() {
        // A wide domain guarantees thousands of distinct sequences (incidence skips Zobrist duplicates), all funneling into four edges, so each edge's incidence is far past 2. A counter that wrapped instead of saturating would resurface here as a phantom singleton or doubleton.
        let source = SyntheticCoverageSource<Int>(edgeCount: 8, edges: { value in
            [value & 0b11]
        })
        let runner = FuzzRunner(
            gen: Gen.choose(in: 0 ... 100_000 as ClosedRange<Int>),
            property: { _ in .pass },
            source: source,
            configuration: FuzzRunnerConfiguration(
                budgetNanoseconds: 60_000_000_000,
                seed: 5,
                attemptLimit: 3000
            )
        )
        let result = runner.run()
        #expect(result.totalAttempts >= 3000)
        #expect(result.edgeSingletonCount == 0)
        #expect(result.edgeDoubletonCount == 0)
    }

    @Test("Seam defaults produce identical output across refactors")
    func seamRegressionGuard() {
        // Exercises the configuration seams (reduceStrategy, prune) at their defaults (nil). The pinned seed and attempt limit make the result deterministic; any behavioral change in the seam plumbing will shift these assertions.
        let property: @Sendable (Int) -> FuzzVerdict = { value in
            (value > 40 && value < 60) || value > 940 ? .fail(.returnedFalse) : .pass
        }
        let runner = FuzzRunner(
            gen: Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
            property: property,
            source: bucketedSource(),
            configuration: FuzzRunnerConfiguration(
                budgetNanoseconds: 60_000_000_000,
                seed: 11,
                attemptLimit: 1500
            )
        )
        let result = runner.run()

        #expect(result.clusters.count == 2)
        let descriptions = Set(result.clusters.map(\.reducedDescription))
        #expect(descriptions == Set(["41", "941"]))
        #expect(result.termination == .attemptLimitReached)
        #expect(result.screeningAttempts > 0)
        #expect(result.samplingAttempts > 0)
        #expect(result.mutationAttempts > 0)
        #expect(result.totalAttempts >= 1500)
        for cluster in result.clusters {
            #expect(cluster.reducedCount >= 1)
        }
    }
}

// MARK: - Helpers

/// A synthetic SUT model over `Int`: coarse value buckets plus threshold edges, giving the corpus real novelty structure to climb.
private func bucketedSource() -> SyntheticCoverageSource<Int> {
    SyntheticCoverageSource<Int>(edgeCount: 32, edges: { value in
        var edges = [abs(value) % 10]
        if value > 500 {
            edges.append(10)
        }
        if value < 5 {
            edges.append(11)
        }
        if value > 95 {
            edges.append(12)
        }
        return edges
    })
}
