import Exhaust
import ExhaustTestSupport
import Testing

@Suite("Generator errors surface as test issues")
struct GeneratorErrorSurfacingTests {
    @Test("Sparse filter reports validity issue")
    func sparseFilterReportsIssue() {
        let gen = #gen(.int(in: 0 ... 100)).filter { _ in false }
        withKnownIssue {
            #exhaust(gen, .budget(.custom(screening: 0, sampling: 10)), .suppress(.logs)) { _ in
                true
            }
        }
    }

    @Test("Sparse filter in screening phase reports validity issue")
    func sparseFilterInScreeningReportsIssue() {
        let gen = #gen(.int(in: 0 ... 100)).filter { _ in false }
        withKnownIssue {
            #exhaust(gen, .budget(.custom(screening: 10, sampling: 0)), .suppress(.logs)) { _ in
                true
            }
        }
    }
}
