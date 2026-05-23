import Testing
@testable import Exhaust

struct SwiftTestingIntegrationTests {
    // MARK: - Void property with #expect

    @Test func `void property reduces to minimal counterexample`() {
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppress(.issueReporting),
            .budget(.custom(coverage: 0, sampling: 50)),
            .randomOnly
        ) { value in
            #expect(value < 50)
        }
        #expect(result == 50, "Minimal counterexample for value < 50 on 0...100 should be 50")
    }

    @Test func `void property with require`() {
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppress(.issueReporting),
            .budget(.custom(coverage: 0, sampling: 50)),
            .randomOnly
        ) { value in
            try #require(value < 50)
        }
        #expect(result != nil, "Should find a counterexample via #require")
        if let result {
            #expect(result == 50, "Minimal counterexample should be 50")
        }
    }

    @Test func `void property passes when no failure`() {
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppress(.issueReporting),
            .budget(.custom(coverage: 0, sampling: 20)),
            .randomOnly
        ) { value in
            #expect(value >= 0)
            #expect(value <= 100)
        }
        #expect(result == nil, "All values in 0...100 should pass")
    }

    @Test func `void property with multiple expect failures`() {
        let result = #exhaust(
            #gen(.int(in: -10 ... 10)),
            .suppress(.issueReporting),
            .budget(.custom(coverage: 0, sampling: 50)),
            .randomOnly
        ) { value in
            #expect(value >= 0)
            #expect(value <= 5)
        }
        #expect(result != nil, "Should find a counterexample")
    }

    @Test func `void property with thrown error`() {
        struct TestError: Error {}
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppress(.issueReporting),
            .randomOnly
        ) { value in
            if value >= 50 {
                throw TestError()
            }
        }
        #expect(result != nil, "Should detect thrown errors as failures")
    }

    // MARK: - Bool property unchanged

    @Test func `bool property still works`() {
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppress(.issueReporting),
            .randomOnly
        ) { value in
            value < 50
        }
        #expect(result == 50, "Bool property should still work and reduce to 50")
    }

    // MARK: - Overload resolution

    @Test func `bool closure resolves to bool overload`() {
        // { value in value < 50 } returns Bool — uses #exhaust.
        let result: Int? = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppress(.issueReporting),
            .randomOnly
        ) { value in
            value < 50
        }
        #expect(result == 50)
    }

    @Test func `expect closure resolves to void overload`() {
        // { value in #expect(value < 50) } returns Void — should resolve to Void overload.
        let result: Int? = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppress(.issueReporting),
            .randomOnly
        ) { value in
            #expect(value < 50)
        }
        #expect(result == 50)
    }

    // MARK: - Replay with numeric seed

    @Test func `replay with numeric seed`() {
        let result1 = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppress(.issueReporting),
            .replay(42),
            .randomOnly
        ) { value in
            value < 50
        }

        let result2 = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppress(.issueReporting),
            .replay(42),
            .randomOnly
        ) { value in
            value < 50
        }

        #expect(result1 == result2, "Numeric replay should be deterministic")
    }

    // MARK: - ReplaySeed literals

    @Test func `replay seed integer literal`() {
        let seed: ReplaySeed = 42
        #expect(seed.resolve() == 42)
    }

    @Test func `replay seed invalid string returns nil`() {
        let seed = ReplaySeed.encoded("INVALID!!!")
        #expect(seed.resolve() == nil)
    }

    // MARK: - Configuration Trait

    @Test(.exhaust(.budget(.thorough)))
    func `trait sets budget`() {
        // The trait sets .thorough (sampling: 600). Verify the trait budget is applied
        // instead of the default .standard (200) by checking the iteration count.
        var capturedReport: ExhaustReport?
        let result = #exhaust(
            #gen(.int(in: Int.min ... Int.max)),
            .suppress(.issueReporting),
            .randomOnly,
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

    @Test(.exhaust(.budget(.standard)))
    func `trait budget overridden by inline`() {
        // Trait sets .standard, inline sets a custom budget. Inline should win.
        var capturedReport: ExhaustReport?
        let result = #exhaust(
            #gen(.int(in: 0 ... 10)),
            .suppress(.issueReporting),
            .budget(.custom(coverage: 0, sampling: 5)),
            .randomOnly,
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

    @Test(.exhaust(.regressions("1A")))
    func `trait with regression seed that fails`() {
        // Seed "1A" (= 42) should reproduce a counterexample for value < 50 on 0...100.
        let result = #exhaust(
            #gen(.int(in: 0 ... 100)),
            .suppress(.issueReporting)
        ) { value in
            #expect(value < 50)
        }
        #expect(result != nil, "Regression seed should find a counterexample")
    }

    @Test(.exhaust(.budget(.standard), .regressions("0")))
    func `trait with passing regression seed`() {
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
