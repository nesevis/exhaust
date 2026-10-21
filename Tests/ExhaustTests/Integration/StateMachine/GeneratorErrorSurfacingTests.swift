import Exhaust
import ExhaustTestSupport
import Testing

@Suite("Generator errors surface as test issues")
struct GeneratorErrorSurfacingTests {
    @Test("An always-rejecting filter reports an issue in either phase", arguments: PropertyTestPhase.allCases)
    func sparseFilterReportsIssue(phase: PropertyTestPhase) {
        let gen = #gen(.int(in: 0 ... 100)).filter { _ in false }
        withKnownIssue {
            #exhaust(gen, .budget(phase.budget(iterations: 10)), .suppress(.logs)) { _ in
                true
            }
        }
    }
}
