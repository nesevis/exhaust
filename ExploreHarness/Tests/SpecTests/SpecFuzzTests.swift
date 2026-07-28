import SpecFixture
import Exhaust
import ExhaustCore
import MatrixSpecs
import Testing

@Suite("Spec fuzz validation", .serialized)
struct SpecFuzzTests {
    @Test("A fuzz run finds at least one fault in the bounded queue spec")
    func findsAtLeastOneFault() async {
        let report = await #explore(
            BoundedQueueSpec.self,
            mode: .sequential,
            time: .seconds(5),
            .commandLimit(40),
            .suppress(.issueReporting)
        )
        #expect(report.clusters.isEmpty == false)
        #expect(report.totalAttempts > 0)
    }
}
