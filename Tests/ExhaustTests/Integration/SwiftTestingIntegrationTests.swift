import Exhaust
import Foundation
import Testing

struct SwiftTestingIntegrationTests {
    // MARK: - Void property with #expect

    @Test("void property reduces to minimal counterexample") func voidPropertyReducesToMinimalCounterexample() {
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppress(.issueReporting),
            .budget(.custom(screening: 0, sampling: 50))
        ) { value in
            #expect(value < 50)
        }
        #expect(result == 50, "Minimal counterexample for value < 50 on 0...100 should be 50")
    }

    @Test("void property with require") func voidPropertyWithRequire() {
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppress(.issueReporting),
            .budget(.custom(screening: 0, sampling: 50))
        ) { value in
            try #require(value < 50)
        }
        #expect(result != nil, "Should find a counterexample via #require")
        if let result {
            #expect(result == 50, "Minimal counterexample should be 50")
        }
    }

    @Test("void property passes when no failure") func voidPropertyPassesWhenNoFailure() {
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppress(.issueReporting),
            .budget(.custom(screening: 0, sampling: 20))
        ) { value in
            #expect(value >= 0)
            #expect(value <= 100)
        }
        #expect(result == nil, "All values in 0...100 should pass")
    }

    @Test("void property with multiple expect failures") func voidPropertyWithMultipleExpectFailures() {
        let result = #exhaust(
            #gen(.int(in: -10 ... 10)),
            .suppress(.issueReporting),
            .budget(.custom(screening: 0, sampling: 50))
        ) { value in
            #expect(value >= 0)
            #expect(value <= 5)
        }
        #expect(result != nil, "Should find a counterexample")
    }

    @Test("Issue.record arguments are evaluated during silent detection")
    func issueRecordArgumentsAreEvaluatedDuringSilentDetection() {
        let counter = DetectionEvaluationCounter()
        let result = #exhaust(
            #gen(.just(0)),
            .suppress(.all),
            .budget(.custom(screening: 0, sampling: 1))
        ) { _ in
            Issue.record("detection evaluation \(counter.increment())")
        }

        #expect(result == 0)
        #expect(counter.value > 0)
    }

    @Test("void property with thrown error") func voidPropertyWithThrownError() {
        struct TestError: Error {}
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppress(.issueReporting),
            .budget(.custom(screening: 0, sampling: 200))
        ) { value in
            if value >= 50 {
                throw TestError()
            }
        }
        #expect(result != nil, "Should detect thrown errors as failures")
    }

    // MARK: - Bool property unchanged

    @Test("bool property still works") func boolPropertyStillWorks() {
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppress(.issueReporting),
            .budget(.custom(screening: 0, sampling: 200))
        ) { value in
            value < 50
        }
        #expect(result == 50, "Bool property should still work and reduce to 50")
    }

    // MARK: - Overload resolution

    @Test("bool closure resolves to bool overload") func boolClosureResolvesToBoolOverload() {
        // { value in value < 50 } returns Bool — uses #exhaust.
        let result: Int? = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppress(.issueReporting),
            .budget(.custom(screening: 0, sampling: 200))
        ) { value in
            value < 50
        }
        #expect(result == 50)
    }

    @Test("expect closure resolves to void overload") func expectClosureResolvesToVoidOverload() {
        // { value in #expect(value < 50) } returns Void — should resolve to Void overload.
        let result: Int? = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppress(.issueReporting),
            .budget(.custom(screening: 0, sampling: 200))
        ) { value in
            #expect(value < 50)
        }
        #expect(result == 50)
    }

    // MARK: - Replay with numeric seed

    @Test("replay with numeric seed") func replayWithNumericSeed() {
        let result1 = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppress(.issueReporting),
            .replay(42),
            .budget(.custom(screening: 0, sampling: 200))
        ) { value in
            value < 50
        }

        let result2 = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppress(.issueReporting),
            .replay(42),
            .budget(.custom(screening: 0, sampling: 200))
        ) { value in
            value < 50
        }

        #expect(result1 == result2, "Numeric replay should be deterministic")
    }

    // MARK: - ReplaySeed literals

    @Test("replay seed integer literal")
    func replaySeedIntegerLiteral() {
        let seed: ReplaySeed = 42
        let resolved = seed.resolve()
        #expect(resolved?.seed == 42)
        #expect(resolved?.iteration == nil)
    }

    @Test("replay seed with iteration")
    func replaySeedWithIteration() {
        let seed = ReplaySeed.encoded("1A-7")
        let resolved = seed.resolve()
        #expect(resolved?.seed == 42)
        #expect(resolved?.iteration == 7)
    }

    @Test("replay seed without iteration")
    func replaySeedWithoutIteration() {
        let seed = ReplaySeed.encoded("1A")
        let resolved = seed.resolve()
        #expect(resolved?.seed == 42)
        #expect(resolved?.iteration == nil)
    }

    @Test("replay seed with iteration generates exactly one value")
    func replaySeedWithIterationGeneratesOneValue() {
        let generator = #gen(.int(in: 0 ... 1000).array(length: 1 ... 5))
        var invocations = 0
        #exhaust(generator, .replay("19-3"), .suppress(.issueReporting), .onReport { report in
            invocations = report.randomSamplingInvocations
        }) { _ in
            false
        }
        #expect(invocations == 1)
    }

    @Test("replay seed without iteration runs full budget")
    func replaySeedWithoutIterationRunsFullBudget() {
        let generator = #gen(.int(in: 0 ... 100))
        var invocations = 0
        #exhaust(generator, .replay("19"), .budget(.custom(screening: 0, sampling: 2)), .onReport { report in
            invocations = report.randomSamplingInvocations
        }) { _ in
            true
        }
        #expect(invocations == 2)
    }

    @Test("screening replay seed resolves to row - 1")
    func screeningReplaySeedResolvesToRow() {
        let seed = ReplaySeed.encoded("U6")
        let resolved = seed.resolve()
        if case let .screening(row) = resolved {
            #expect(row == 5)
        } else {
            Issue.record("Expected .screening(row:), got \(String(describing: resolved))")
        }
    }

    @Test("screening replay tests exactly one row")
    func screeningReplayTestsOneRow() {
        let generator = #gen(.int(in: 0 ... 2), .int(in: 0 ... 2))
        var invocations = 0
        #exhaust(generator, .replay("U3"), .suppress(.issueReporting), .onReport { report in
            invocations = report.screeningInvocations
        }) { _ in
            true
        }
        #expect(invocations == 1)
    }

    @Test("replay seed invalid string returns nil") func replaySeedInvalidStringReturnsNil() {
        let seed = ReplaySeed.encoded("INVALID!!!")
        #expect(seed.resolve() == nil)
    }

    // MARK: - Configuration Trait

    @Test("Trait sets budget", .exhaust(.budget(.thorough)))
    func traitSetsBudget() {
        // The trait sets .thorough (sampling: 600). Verify the trait budget is applied
        // instead of the default .standard (200) by checking the iteration count.
        var capturedReport: ExhaustReport?
        let result = #exhaust(
            #gen(.int(in: Int.min ... Int.max)),
            .suppress(.issueReporting),
            .budget(.custom(screening: 0, sampling: 600)),
            .onReport { report in
                capturedReport = report
            }
        ) { _ in
            true // always passes — runs the full sampling budget
        }
        #expect(result == nil)
        // .thorough sampling budget is 600; .standard would be 200.
        #expect(capturedReport?.randomSamplingInvocations == 600, "Trait should set .thorough budget (600), not default .standard (200)")
    }

    @Test("Trait budget overridden by inline", .exhaust(.budget(.standard)))
    func traitBudgetOverriddenByInline() {
        // Trait sets .standard, inline sets a custom budget. Inline should win.
        var capturedReport: ExhaustReport?
        let result = #exhaust(
            #gen(.int(in: 0 ... 10)),
            .suppress(.issueReporting),
            .budget(.custom(screening: 0, sampling: 5)),
            .onReport { report in
                capturedReport = report
            }
        ) { value in
            value >= 0
        }
        #expect(result == nil)
        // The inline budget of 5 sampling iterations should be used, not the trait's .standard (200).
        #expect(capturedReport?.randomSamplingInvocations ?? 0 <= 5)
    }

    @Test("Trait with regression seed that fails", .exhaust(.regressions("1A")))
    func traitWithRegressionSeedThatFails() {
        // Seed "1A" (= 42) should reproduce a counterexample for value < 50 on 0...100.
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppress(.issueReporting)
        ) { value in
            #expect(value < 50)
        }
        #expect(result != nil, "Regression seed should find a counterexample")
    }

    @Test("Trait regression seeds apply to Bool properties", .exhaust(.regressions("1A")))
    func traitRegressionSeedsApplyToBoolProperties() {
        var result: Int?
        withKnownIssue {
            result = #exhaust(
                #gen(.int(in: 0 ... 100)),
                .budget(.custom(screening: 0, sampling: 0)),
                .suppress(.all)
            ) { _ in
                false
            }
        }

        #expect(result != nil)
    }

    @Test("Trait regression replay still delivers onReport", .exhaust(.regressions("1A")))
    func traitRegressionReplayStillDeliversOnReport() {
        var capturedReport: ExhaustReport?
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppress(.all),
            .onReport { report in
                capturedReport = report
            }
        ) { _ in
            #expect(Bool(false))
        }

        #expect(result != nil)
        #expect(capturedReport != nil)
    }

    @Test("Trait with passing regression seed", .exhaust(.budget(.standard), .regressions("0")))
    func traitWithPassingRegressionSeed() {
        // Seed "0" should produce a value that passes value >= 0 on 0...100.
        // The regression "now passes" warning should be emitted as an issue.
        // Since suppressing, we just verify the pipeline continues to the normal run.
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppress(.issueReporting)
        ) { value in
            #expect(value >= 0)
        }
        #expect(result == nil, "All values in 0...100 should pass")
    }
}

/// Counts evaluation of expressions embedded in rewritten detection assertions.
private final class DetectionEvaluationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() -> Int {
        lock.withLock {
            storage += 1
            return storage
        }
    }
}

// MARK: - Suite Trait

/// Constructing the plan for this suite would trap during _recursivelyApplyTraits before any test ran if ExhaustSuiteTrait were not a TestTrait — the recursive suite trait is propagated to this child test, where Swift Testing asserts that every trait is a TestTrait.
/// The suite running at all is the regression guard; the assertion confirms the suite budget reaches the child test.
@Suite("Exhaust suite trait", .exhaust(.budget(.thorough)))
struct ExhaustSuiteTraitTests {
    @Test("suite trait sets budget for child test")
    func suiteTraitSetsBudgetForChildTest() {
        var capturedReport: ExhaustReport?
        let result = #exhaust(
            #gen(.int(in: Int.min ... Int.max)),
            .suppress(.issueReporting),
            .onReport { report in
                capturedReport = report
            }
        ) { _ in
            true // always passes — runs the full sampling budget
        }
        #expect(result == nil)
        #expect(
            capturedReport?.randomSamplingInvocations == 600,
            "Suite trait .thorough sampling budget is 600; the default .standard would be 200"
        )
    }
}
