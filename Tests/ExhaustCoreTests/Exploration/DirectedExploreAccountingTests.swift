import ExhaustCore
import Testing

@Suite("Directed explore accounting")
struct DirectedExploreAccountingTests {
    @Test("Passing run separates warm-up, regression, and directed sampling invocations")
    func passingRunSeparatesSamplingPhases() throws {
        let maxAttemptsPerDirection = 1
        var observedPropertyInvocations = 0
        var runner = DirectedExploreRunner(
            gen: Gen.just(0),
            property: { _ in
                observedPropertyInvocations += 1
                return true
            },
            directions: [
                (name: "unreachable", predicate: { _ in false }),
            ],
            hitsPerDirection: 1,
            maxAttemptsPerDirection: maxAttemptsPerDirection,
            seed: 42,
            regressionSeeds: [7]
        )

        let result = try runner.run()

        #expect(result.invocations.warmup == 100)
        #expect(result.invocations.regression == 1)
        #expect(result.invocations.directedSampling == maxAttemptsPerDirection)
        #expect(result.invocations.reduction == 0)
        #expect(result.invocations.total
            == result.invocations.warmup
            + result.invocations.regression
            + result.invocations.directedSampling
            + result.invocations.reduction)
        #expect(observedPropertyInvocations == result.invocations.total)
        #expect(result.warmupSamples == result.invocations.warmup)
        #expect(result.directionCoverage[0].directedSamplingSamples == maxAttemptsPerDirection)
    }

    @Test("Failing run includes reducer probes without charging the tuning pool")
    func failingRunIncludesReducerInvocations() throws {
        var observedPropertyInvocations = 0
        var runner = DirectedExploreRunner(
            gen: Gen.choose(in: 0 ... 100),
            property: { _ in
                observedPropertyInvocations += 1
                return false
            },
            directions: [
                (name: "any", predicate: { _ in true }),
            ],
            hitsPerDirection: 1,
            maxAttemptsPerDirection: 1,
            seed: 42
        )

        let result = try runner.run()

        #expect(result.termination == .propertyFailed)
        #expect(result.invocations.warmup == 1)
        #expect(result.invocations.regression == 0)
        #expect(result.invocations.directedSampling == 0)
        #expect(result.invocations.reduction > 0)
        #expect(result.directionCoverage[0].directedSamplingSamples == 0)
        #expect(observedPropertyInvocations == result.invocations.total)
    }

    @Test("Direction-rejected reducer proposals do not count as property invocations")
    func directionRejectedReducerProposalsDoNotCountAsPropertyInvocations() throws {
        let generator = Gen.choose(in: 0 ... 100)
        let seed: UInt64 = 42
        var previewInterpreter = ValueInterpreter(
            generator,
            seed: seed,
            maxRuns: 1
        )
        let originalValue = try #require(try previewInterpreter.next())
        var observedPropertyInvocations = 0
        var runner = DirectedExploreRunner(
            gen: generator,
            property: { _ in
                observedPropertyInvocations += 1
                return false
            },
            directions: [
                (name: "original value", predicate: { $0 == originalValue }),
            ],
            hitsPerDirection: 1,
            maxAttemptsPerDirection: 1,
            seed: seed
        )

        let result = try runner.run()

        #expect(result.counterexample == originalValue)
        #expect(observedPropertyInvocations == result.invocations.total)
    }
}
