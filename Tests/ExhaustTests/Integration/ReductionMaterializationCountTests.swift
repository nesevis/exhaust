import Exhaust
import Testing

@Suite("Reduction materialization counts")
struct ReductionMaterializationCountTests {
    @Test("The materialization total covers lifts through nested binds as well as probe decodes")
    func totalIncludesNestedBindLifts() throws {
        var capturedReport: ExhaustReport?
        let counterexample = #exhaust(
            coupledPairGenerator(),
            reflecting: CoupledPair(first: 113, second: 113),
            .onReport { capturedReport = $0 },
            .suppress(.all)
        ) { pair in
            abs(pair.first - pair.second) > 1 || pair.first < 10
        }

        let report = try #require(capturedReport)
        #expect(counterexample != nil)
        #expect(report.totalMaterializations == report.materializationsBySite.values.reduce(0, +))
        #expect((report.materializationsBySite["decoder"] ?? 0) > 0)
        #expect((report.materializationsBySite["setup"] ?? 0) > 0)
        #expect((report.materializationsBySite["boundValueLift"] ?? 0) > 0)
    }
}

// MARK: - Supporting Types

private struct CoupledPair {
    let first: Int
    let second: Int
}

// MARK: - Helpers

/// Two controllers in separate binds, so reducing one past the other needs a lift through both.
private func coupledPairGenerator() -> ReflectiveGenerator<CoupledPair> {
    #gen(.int(in: 0 ... 10000)).bound(
        forward: { first in
            #gen(.int(in: 0 ... 10000)).bound(
                forward: { second in
                    .just(CoupledPair(first: first, second: second))
                },
                backward: \CoupledPair.second
            )
        },
        backward: \CoupledPair.first
    )
}
