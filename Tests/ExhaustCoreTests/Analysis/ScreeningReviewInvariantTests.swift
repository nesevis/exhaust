import Testing
@testable import ExhaustCore

@Suite("Screening review invariants")
struct ScreeningReviewInvariantTests {
    @Test("Materialization rejections prevent exhaustive completion")
    func materializationRejectionsPreventExhaustiveCompletion() {
        let unfilteredGenerator = Gen.zip(
            Gen.choose(in: UInt64(0) ... 1),
            Gen.choose(in: UInt64(0) ... 1)
        )
        let generator = Gen.filter(
            unfilteredGenerator,
            type: .rejectionSampling,
            predicate: { value in
                value.0 == 0 && value.1 == 0
            },
            sourceLocation: FilterSourceLocation(
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
        )
        var propertyInvocationCount = 0

        let result = ScreeningRunner.run(
            generator,
            screeningBudget: 4,
            property: { _ in
                propertyInvocationCount += 1
                return true
            }
        )

        #expect(propertyInvocationCount == 2)
        guard case .partial = result else {
            Issue.record("Expected rejected rows to prevent exhaustive completion")
            return
        }
    }

    @Test("Covering array preserves every declared domain index")
    func coveringArrayDoesNotSilentlyClampDomains() {
        let declaredDomainSize: UInt64 = 20000
        let generator = BalancedCoveringArrayGenerator(
            domainSizes: [declaredDomainSize, 2]
        )
        var observedFirstParameterValues = Set<UInt64>()

        for _ in 0 ..< Int(declaredDomainSize) {
            guard let row = generator.next() else {
                Issue.record("Expected the spread generator to keep producing rows")
                return
            }
            observedFirstParameterValues.insert(row.values[0])
        }

        #expect(observedFirstParameterValues.max() == declaredDomainSize - 1)
    }
}
