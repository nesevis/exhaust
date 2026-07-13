import ExploreFixture
import Testing

@Suite("Deep fixture ground truth")
struct DeepFixtureSmokeTests {
    @Test("Each planted reproducer triggers exactly its own fault")
    func reproducersTrigger() {
        #expect(throws: AlignmentError.self) { try DeepParser.decode(DeepFixture.reproducerP) }
        #expect(throws: AlignmentError.self) { try DeepParser.decode(DeepFixture.reproducerQ) }
        #expect(throws: OverflowError.self) { try DeepParser.decode(DeepFixture.reproducerR) }
    }

    @Test("The deep slippage pair shares one symptom type but has disjoint minimal forms")
    func slippagePairIsDistinct() {
        #expect(throws: AlignmentError.self) { try DeepParser.decode(DeepFixture.reproducerP) }
        #expect(throws: AlignmentError.self) { try DeepParser.decode(DeepFixture.reproducerQ) }
        #expect(DeepFixture.reproducerP.channel != DeepFixture.reproducerQ.channel)
        #expect(DeepFixture.reproducerP != DeepFixture.reproducerQ)
    }

    @Test("Zeroing any reproducer stops triggering its fault", arguments: [
        DeepFixture.reproducerP,
        DeepFixture.reproducerQ,
        DeepFixture.reproducerR,
    ])
    func reproducersCarrySomethingLoadBearing(reproducer: Packet) {
        #expect(throws: (any Error).self) {
            _ = try DeepParser.decode(reproducer)
        }
        let zeroed = Packet(channel: 0, flags: 0, window: 0, commands: [], body: [])
        #expect(throws: Never.self) {
            _ = try DeepParser.decode(zeroed)
        }
    }

    @Test("Eleven pushes stay under fault R's threshold")
    func depthBelowThresholdPasses() {
        let belowThreshold = Packet(
            channel: 0,
            flags: 0,
            window: 0,
            commands: Array(repeating: .push, count: 11),
            body: []
        )
        #expect(throws: Never.self) {
            _ = try DeepParser.decode(belowThreshold)
        }
    }
}
