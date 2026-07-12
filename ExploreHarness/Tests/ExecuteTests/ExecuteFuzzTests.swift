import ExecuteFixture
import Exhaust
import ExhaustCore
import MatrixSpecs
import Testing

@Suite("Execute fuzz validation", .serialized)
struct ExecuteFuzzTests {
    @Test("A fuzz run finds at least one fault in the bounded queue spec")
    func findsAtLeastOneFault() async {
        let report = await #execute(
            BoundedQueueSpec.self,
            time: .seconds(5),
            .commandLimit(40),
            .suppress(.issueReporting)
        )
        #expect(report.clusters.isEmpty == false)
        #expect(report.totalAttempts > 0)
    }
}
