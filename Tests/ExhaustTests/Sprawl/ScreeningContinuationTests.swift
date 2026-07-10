import Exhaust
import ExhaustCore
import Testing

@Suite("ScreeningRunner continue-past-failure tests")
struct ScreeningContinuationTests {
    @Test("Default mode stops at the first failing row")
    func defaultModeStopsAtFirstFailure() {
        let gen = #gen(.int(in: 0 ... 9))
        var examples: [(value: Int, passed: Bool)] = []
        let result = ScreeningRunner.run(
            gen.gen,
            screeningBudget: 100,
            property: { $0 != 3 && $0 != 7 },
            onExample: { value, _, passed in
                examples.append((value, passed))
            }
        )
        guard case let .failure(value, _, _, _, _, _, _, _) = result else {
            Issue.record("Expected .failure, got \(result)")
            return
        }
        #expect(value == 3)
        #expect(examples.count(where: { $0.passed == false }) == 1)
    }

    @Test("Continue-past-failure catalogues every failure and finishes the domain")
    func continuePastFailureCataloguesAll() {
        let gen = #gen(.int(in: 0 ... 9))
        var examples: [(value: Int, passed: Bool)] = []
        let result = ScreeningRunner.run(
            gen.gen,
            screeningBudget: 100,
            continuePastFailure: true,
            property: { $0 != 3 && $0 != 7 },
            onExample: { value, _, passed in
                examples.append((value, passed))
            }
        )
        // A run that saw failures must not claim the domain passed exhaustively.
        guard case let .partial(iterations, _, _, _, _, _) = result else {
            Issue.record("Expected .partial, got \(result)")
            return
        }
        #expect(iterations == 10)
        let failures = examples.filter { $0.passed == false }.map(\.value).sorted()
        #expect(failures == [3, 7])
    }

    @Test("Continue-past-failure with no failures still reports exhaustive")
    func continuePastFailureExhaustive() {
        let gen = #gen(.int(in: 0 ... 9))
        let result = ScreeningRunner.run(
            gen.gen,
            screeningBudget: 100,
            continuePastFailure: true,
            property: { _ in true }
        )
        guard case let .exhaustive(iterations) = result else {
            Issue.record("Expected .exhaustive, got \(result)")
            return
        }
        #expect(iterations == 10)
    }
}
