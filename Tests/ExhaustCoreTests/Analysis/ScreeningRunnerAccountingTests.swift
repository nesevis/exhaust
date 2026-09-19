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
        let observedCandidates = SendableBox<[[UInt64]]>([])
        let generator = Gen.filter(
            unfilteredGenerator,
            type: .rejectionSampling,
            predicate: { value in
                observedCandidates.withValue { $0.append([value.0, value.1]) }
                return value.0 == 0 && value.1 == 0
            },
            sourceLocation: FilterSourceLocation(
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
        )
        var acceptedPoints: [[UInt64]] = []

        let result = ScreeningRunner.run(
            generator,
            screeningBudget: 4,
            coveringSeed: 0,
            property: { value in
                acceptedPoints.append([value.0, value.1])
                return true
            }
        )

        guard case let .partial(summary, _, _, _, _, _) = result else {
            Issue.record("Expected rejected rows to leave screening incomplete")
            return
        }
        #expect(summary.rowAttempts == 4)
        #expect(summary.propertyInvocations == 1)
        #expect(summary.rejectedRows == 3)
        #expect(summary.rowAttempts == summary.propertyInvocations + summary.rejectedRows)
        #expect(acceptedPoints.count == summary.propertyInvocations)
        #expect(acceptedPoints == [[0, 0]])
        // Analysis probes precede screening. Each of the four guided rows invokes this predicate once, including rows rejected before the property runs.
        let attemptedPoints = observedCandidates.value.suffix(4)
        #expect(attemptedPoints.count == 4)
        #expect(Set(attemptedPoints) == Set([[UInt64(0), 0], [0, 1], [1, 0], [1, 1]]))
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
}
