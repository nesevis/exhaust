import Exhaust
import ExhaustTestSupport
import Testing

@Suite("Generator errors surface as test issues")
struct GeneratorErrorSurfacingTests {
    @Test("An always-rejecting filter reports an issue in either phase", arguments: [false, true])
    func sparseFilterReportsIssue(screening: Bool) {
        let gen = #gen(.int(in: 0 ... 100)).filter { _ in false }
        withKnownIssue {
            #exhaust(gen, .budget(.custom(screening: screening ? 10 : 0, sampling: screening ? 0 : 10)), .suppress(.logs)) { _ in
                true
            }
        }
    }
}
