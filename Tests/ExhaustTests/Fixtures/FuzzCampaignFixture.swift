import ExhaustCore
@testable import Exhaust

/// Shares deterministic campaign reports across attachment and wire-format tests.
enum FuzzCampaignFixture {
    /// Supplies the same deterministic failing search to record and attachment tests.
    static func failingReport(seed: UInt64, range: ClosedRange<Int> = 0 ... 100) -> FuzzReport {
        __ExhaustRuntime.runExploreTimeCore(
            gen: Gen.choose(in: range),
            time: .seconds(1),
            settings: [.replay(.numeric(seed)), .suppress(.all)],
            source: .injected(SyntheticCoverageSource<Int>(edgeCount: 4, edges: { _ in [0] })),
            configure: { $0.attemptLimit = 20 },
            property: { _ in .fail(.returnedFalse) }
        )
    }
}
