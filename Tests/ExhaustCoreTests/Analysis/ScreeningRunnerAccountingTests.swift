import Testing
@testable import ExhaustCore

@Suite("ScreeningRunner accounting")
struct ScreeningRunnerAccountingTests {
    @Test("Rejected rows are counted separately and prevent exhaustive completion")
    func rejectedRowsAreCountedSeparatelyAndPreventExhaustiveCompletion() {
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
            coveringSeed: 0,
            property: { _ in
                propertyInvocationCount += 1
                return true
            }
        )

        guard case let .partial(summary, _, _, _, _, _) = result else {
            Issue.record("Expected rejected rows to leave screening incomplete")
            return
        }
        #expect(summary.rowAttempts == 4)
        #expect(summary.propertyInvocations == 2)
        #expect(summary.rejectedRows == 2)
        #expect(summary.rowAttempts == summary.propertyInvocations + summary.rejectedRows)
        #expect(propertyInvocationCount == summary.propertyInvocations)
    }

    @Test("A 3-parameter space the budget can finish reports exhaustive")
    func threeParameterSmallSpaceSaturatesToExhaustive() {
        // A bare covering array stops once all pairs are covered, which for 3+ parameters is a strict subset of the space, so `rowAttempts >= totalSpace` was unreachable and this result could never fire. The saturating generator spends the leftover budget on the remainder and makes the gate live.
        let generator = Gen.zip(
            Gen.choose(in: UInt64(0) ... 1),
            Gen.choose(in: UInt64(0) ... 1),
            Gen.choose(in: UInt64(0) ... 1)
        )
        var observedPoints = Set<[UInt64]>()

        let result = ScreeningRunner.run(
            generator,
            screeningBudget: 200,
            coveringSeed: 0,
            property: { value in
                observedPoints.insert([value.0, value.1, value.2])
                return true
            }
        )

        guard case let .exhaustive(summary) = result else {
            Issue.record("Expected exhaustive completion, got \(result)")
            return
        }
        #expect(summary.rowAttempts == 8)
        #expect(observedPoints.count == 8)
    }

    @Test("Covering array applies its documented per-parameter domain cap")
    func coveringArrayAppliesPerParameterDomainCap() {
        let declaredDomainSize: UInt64 = 20000
        let parameterCount = 2
        let effectiveDomainSize = BalancedCoveringArrayGenerator.maxDomainSize / parameterCount
        let generator = BalancedCoveringArrayGenerator(
            domainSizes: [declaredDomainSize, 2]
        )
        var observedFirstParameterValues = Set<UInt64>()

        for _ in 0 ..< effectiveDomainSize {
            guard let row = generator.next() else {
                Issue.record("Expected the spread generator to keep producing rows")
                return
            }
            observedFirstParameterValues.insert(row.values[0])
        }

        #expect(observedFirstParameterValues.count == effectiveDomainSize)
        #expect(observedFirstParameterValues.max() == UInt64(effectiveDomainSize - 1))
    }
}
