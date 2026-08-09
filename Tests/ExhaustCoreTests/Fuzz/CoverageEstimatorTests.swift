import ExhaustCore
import Testing

@Suite("STADS coverage estimator tests")
struct CoverageEstimatorTests {
    @Test("Discovery probability is the singleton fraction of incidences, damped toward the undiscovered estimate")
    func discoveryProbabilityArithmetic() {
        // Q₁ = 7 over V = 350,000 incidences is 2e-5; the Eq 28 factor nQ̂₀/(nQ̂₀ + Q₁) with n = 1000
        // and Q̂₀ = 5 is 5000/5007, giving 1.997203914520e-5.
        let probability = CoverageEstimators.nextDiscoveryProbability(
            singletons: 7,
            incidenceTotal: 350_000,
            undiscovered: 5,
            attempts: 1000
        )
        #expect(abs(probability - 1.997203914520e-5) < 1e-15)
    }

    @Test("Discovery probability falls back to the plain ratio without an undiscovered estimate")
    func discoveryProbabilityWithoutUndiscovered() {
        // Nothing left to discover means no damping term; the estimate is Q₁/V.
        let probability = CoverageEstimators.nextDiscoveryProbability(
            singletons: 7,
            incidenceTotal: 350_000,
            undiscovered: 0,
            attempts: 1000
        )
        #expect(abs(probability - 2e-5) < 1e-15)
    }

    @Test("Discovery probability is zero without singletons or incidences")
    func discoveryProbabilityDegenerate() {
        #expect(CoverageEstimators.nextDiscoveryProbability(singletons: 0, incidenceTotal: 1000, undiscovered: 5, attempts: 100) == 0)
        #expect(CoverageEstimators.nextDiscoveryProbability(singletons: 5, incidenceTotal: 0, undiscovered: 5, attempts: 100) == 0)
    }

    @Test("Chao2 matches the hand-computed ratio form")
    func chao2Arithmetic() {
        // S = 70, Q₁ = 6, Q₂ = 3, n = 1000: Ŝ = 70 + (999/1000) · 36/6 = 75.994.
        let estimate = CoverageEstimators.chao2ReachableEdges(covered: 70, singletons: 6, doubletons: 3, attempts: 1000)
        #expect(abs(estimate - 75.994) < 1e-9)
    }

    @Test("Chao2 falls back to the bias-corrected form when doubletons are zero")
    func chao2DegenerateDoubletons() {
        // S = 70, Q₁ = 6, Q₂ = 0, n = 1000: Ŝ = 70 + (999/1000) · 6·5/2 = 84.985.
        let estimate = CoverageEstimators.chao2ReachableEdges(covered: 70, singletons: 6, doubletons: 0, attempts: 1000)
        #expect(abs(estimate - 84.985) < 1e-9)
    }

    @Test("No singletons means the asymptote is the covered count")
    func chao2NoSingletons() {
        let estimate = CoverageEstimators.chao2ReachableEdges(covered: 70, singletons: 0, doubletons: 4, attempts: 1000)
        #expect(estimate == 70)
        // Degenerate attempt counts never divide by zero.
        #expect(CoverageEstimators.chao2ReachableEdges(covered: 3, singletons: 2, doubletons: 1, attempts: 1) == 3)
        #expect(CoverageEstimators.chao2ReachableEdges(covered: 0, singletons: 0, doubletons: 0, attempts: 0) == 0)
    }

    @Test("iChao2 adds the tripleton and quadrupleton correction")
    func iChao2Arithmetic() {
        // S = 70, Q₁ = 6, Q₂ = 3, Q₃ = 4, Q₄ = 2, n = 1000. Chao2 is 75.994; the correction is
        // (997/1000) · (4/8) · max(6 − (997/999) · 12/4, 0) = 1.498493993994.
        let estimate = CoverageEstimators.iChao2ReachableEdges(
            covered: 70,
            singletons: 6,
            doubletons: 3,
            tripletons: 4,
            quadrupletons: 2,
            attempts: 1000
        )
        #expect(abs(estimate - 77.492493993994) < 1e-9)
    }

    @Test("iChao2 degrades to Chao2 without quadrupletons")
    func iChao2WithoutQuadrupletons() {
        // The correction divides by Q₄, so a run that never hit an edge four times keeps the plain bound.
        let estimate = CoverageEstimators.iChao2ReachableEdges(
            covered: 70,
            singletons: 6,
            doubletons: 3,
            tripletons: 4,
            quadrupletons: 0,
            attempts: 1000
        )
        #expect(abs(estimate - 75.994) < 1e-9)
    }
}
