import ExhaustCore
import Testing

@Suite("STADS coverage estimator tests")
struct CoverageEstimatorTests {
    @Test("Good-Turing is the singleton fraction")
    func goodTuringArithmetic() {
        // Hand-computed: 7 singleton edges over 350,000 attempts.
        let probability = CoverageEstimators.goodTuringNextDiscoveryProbability(singletons: 7, attempts: 350_000)
        #expect(abs(probability - 2e-5) < 1e-12)
        #expect(CoverageEstimators.goodTuringNextDiscoveryProbability(singletons: 0, attempts: 1000) == 0)
        #expect(CoverageEstimators.goodTuringNextDiscoveryProbability(singletons: 5, attempts: 0) == 0)
    }

    @Test("Chao1 matches the hand-computed ratio form")
    func chao1Arithmetic() {
        // S = 70, f₁ = 6, f₂ = 3, n = 1000: Ŝ = 70 + (999/1000) · 36/6 = 75.994.
        let estimate = CoverageEstimators.chao1ReachableEdges(covered: 70, singletons: 6, doubletons: 3, attempts: 1000)
        #expect(abs(estimate - 75.994) < 1e-9)
    }

    @Test("Chao1 falls back to the bias-corrected form when doubletons are zero")
    func chao1DegenerateDoubletons() {
        // S = 70, f₁ = 6, f₂ = 0, n = 1000: Ŝ = 70 + (999/1000) · 6·5/2 = 84.985.
        let estimate = CoverageEstimators.chao1ReachableEdges(covered: 70, singletons: 6, doubletons: 0, attempts: 1000)
        #expect(abs(estimate - 84.985) < 1e-9)
    }

    @Test("No singletons means the asymptote is the covered count")
    func chao1NoSingletons() {
        let estimate = CoverageEstimators.chao1ReachableEdges(covered: 70, singletons: 0, doubletons: 4, attempts: 1000)
        #expect(estimate == 70)
        // Degenerate attempt counts never divide by zero.
        #expect(CoverageEstimators.chao1ReachableEdges(covered: 3, singletons: 2, doubletons: 1, attempts: 1) == 3)
        #expect(CoverageEstimators.chao1ReachableEdges(covered: 0, singletons: 0, doubletons: 0, attempts: 0) == 0)
    }
}
