import Testing
@testable import Exhaust
import ExhaustCore

@Suite struct SwiftTestingIntegrationTests {
    // MARK: - Void property with #expect

    @Test func voidPropertyReducesToMinimalCounterexample() {
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppressIssueReporting,
            .budget(.custom(coverage: 0, sampling: 50, reduction: .fast)),
            .randomOnly
        ) { value in
            #expect(value < 50)
        }
        #expect(result == 50, "Minimal counterexample for value < 50 on 0...100 should be 50")
    }

    @Test func voidPropertyWithRequire() {
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppressIssueReporting,
            .budget(.custom(coverage: 0, sampling: 50, reduction: .fast)),
            .randomOnly
        ) { value in
            try #require(value < 50)
        }
        #expect(result != nil, "Should find a counterexample via #require")
        if let result {
            #expect(result == 50, "Minimal counterexample should be 50")
        }
    }

    @Test func voidPropertyPassesWhenNoFailure() {
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppressIssueReporting,
            .budget(.custom(coverage: 0, sampling: 20, reduction: .fast)),
            .randomOnly
        ) { value in
            #expect(value >= 0)
            #expect(value <= 100)
        }
        #expect(result == nil, "All values in 0...100 should pass")
    }

    @Test func voidPropertyWithMultipleExpectFailures() {
        let result = #exhaust(
            #gen(.int(in: -10 ... 10)),
            .suppressIssueReporting,
            .budget(.custom(coverage: 0, sampling: 50, reduction: .fast)),
            .randomOnly
        ) { value in
            #expect(value >= 0)
            #expect(value <= 5)
        }
        #expect(result != nil, "Should find a counterexample")
    }

    @Test func voidPropertyWithThrownError() {
        struct TestError: Error {}
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppressIssueReporting,
            .budget(.custom(coverage: 0, sampling: 50, reduction: .fast)),
            .randomOnly
        ) { value in
            if value >= 50 {
                throw TestError()
            }
        }
        #expect(result != nil, "Should detect thrown errors as failures")
    }

    // MARK: - Bool property unchanged

    @Test func boolPropertyStillWorks() {
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppressIssueReporting,
            .budget(.custom(coverage: 0, sampling: 50, reduction: .fast)),
            .randomOnly
        ) { value in
            value < 50
        }
        #expect(result == 50, "Bool property should still work and reduce to 50")
    }

    // MARK: - Overload resolution

    @Test func boolClosureResolvesToBoolOverload() {
        // { value in value < 50 } returns Bool — uses #exhaust.
        let result: Int? = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppressIssueReporting,
            .budget(.custom(coverage: 0, sampling: 50, reduction: .fast)),
            .randomOnly
        ) { value in
            value < 50
        }
        #expect(result == 50)
    }

    @Test func expectClosureResolvesToVoidOverload() {
        // { value in #expect(value < 50) } returns Void — should resolve to Void overload.
        let result: Int? = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppressIssueReporting,
            .budget(.custom(coverage: 0, sampling: 50, reduction: .fast)),
            .randomOnly
        ) { value in
            #expect(value < 50)
        }
        #expect(result == 50)
    }

    // MARK: - Replay seed with Crockford Base32

    @Test func replayWithBase32String() {
        // First run to get a counterexample and seed
        var capturedSeed: UInt64?
        let firstResult = #exhaust(
            #gen(.int(in: 0 ... 1000)),
            .suppressIssueReporting,
            .budget(.custom(coverage: 0, sampling: 50, reduction: .fast)),
            .randomOnly,
            .onReport { report in
                capturedSeed = report.seed
            }
        ) { value in
            value < 500
        }

        guard let firstResult, let seed = capturedSeed else {
            Issue.record("Should find a counterexample with a seed")
            return
        }

        // Replay with the Crockford Base32 encoded seed
        let encoded = CrockfordBase32.encode(seed)
        let replayResult = #exhaust(
            #gen(.int(in: 0 ... 1000)),
            .suppressIssueReporting,
            .replay(ReplaySeed.encoded(encoded)),
            .budget(.custom(coverage: 0, sampling: 50, reduction: .fast)),
            .randomOnly
        ) { value in
            value < 500
        }

        #expect(replayResult == firstResult, "Replay with Base32 seed should produce the same counterexample")
    }

    @Test func replayWithNumericSeed() {
        let result1 = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppressIssueReporting,
            .replay(42),
            .budget(.custom(coverage: 0, sampling: 50, reduction: .fast)),
            .randomOnly
        ) { value in
            value < 50
        }

        let result2 = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppressIssueReporting,
            .replay(42),
            .budget(.custom(coverage: 0, sampling: 50, reduction: .fast)),
            .randomOnly
        ) { value in
            value < 50
        }

        #expect(result1 == result2, "Numeric replay should be deterministic")
    }

    // MARK: - Crockford Base32 round-trip via ReplaySeed

    @Test func replaySeedStringLiteral() {
        let seed: ReplaySeed = "3RT5GH"
        #expect(seed.resolve() == CrockfordBase32.decode("3RT5GH"))
    }

    @Test func replaySeedIntegerLiteral() {
        let seed: ReplaySeed = 42
        #expect(seed.resolve() == 42)
    }

    @Test func replaySeedInvalidStringReturnsNil() {
        let seed = ReplaySeed.encoded("INVALID!!!")
        #expect(seed.resolve() == nil)
    }
}
