import Testing
@testable import Exhaust

@Suite("All-skip concurrent contract tests")
struct AllSkipConcurrentTests {
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("100% skip rate does not hang or crash")
    func allCommandsSkip() async {
        let result = await __runContractConcurrent(
            AlwaysSkipSpec.self,
            settings: [.commandLimit(6), .budget(.custom(coverage: 0, sampling: 50)), .suppress(.issueReporting)]
        )
        #expect(result == nil, "A spec where every command skips should produce no failure")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("100% skip rate with coverage phase")
    func allCommandsSkipWithCoverage() async {
        let result = await __runContractConcurrent(
            AlwaysSkipSpec.self,
            settings: [.commandLimit(4), .budget(.custom(coverage: 100, sampling: 50)), .suppress(.issueReporting)]
        )
        #expect(result == nil, "Coverage phase should handle 100% skip rate gracefully")
    }
}

// MARK: - Spec

@Contract
final class AlwaysSkipSpec {
    @Model
    var count: Int = 0
    @SystemUnderTest
    var value: Int = 0

    @Invariant
    func alwaysTrue() -> Bool {
        true
    }

    @Command(weight: 1)
    func skipAlways() async throws {
        throw skip()
    }

    @Command(weight: 1)
    func skipAlwaysToo() async throws {
        throw skip()
    }
}
