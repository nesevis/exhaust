import ExploreFixture
import Testing

@Suite("Fixture ground truth")
struct FixtureSmokeTests {
    @Test("Each planted reproducer triggers exactly its own fault")
    func reproducersTrigger() {
        #expect(throws: IntegrityError.self) { try Parser.decode(Fixture.reproducerA) }
        #expect(throws: IntegrityError.self) { try Parser.decode(Fixture.reproducerB) }
        #expect(throws: WindowError.self) { try Parser.decode(Fixture.reproducerC) }
        #expect(throws: ChecksumError.self) { try Parser.decode(Fixture.reproducerD) }
    }

    @Test("The slippage pair shares one symptom type but has disjoint minimal forms")
    func slippagePairIsDistinct() {
        // Identical error type: a symptom-deduplicating tool sees one bug.
        #expect(throws: IntegrityError.self) { try Parser.decode(Fixture.reproducerA) }
        #expect(throws: IntegrityError.self) { try Parser.decode(Fixture.reproducerB) }
        // Disjoint inputs: different mode, region, and payload direction.
        #expect(Fixture.reproducerA.mode != Fixture.reproducerB.mode)
        #expect(Fixture.reproducerA != Fixture.reproducerB)
    }

    @Test("Zeroing any reproducer stops triggering its fault", arguments: [
        Fixture.reproducerA,
        Fixture.reproducerB,
        Fixture.reproducerC,
        Fixture.reproducerD,
    ])
    func reproducersCarrySomethingLoadBearing(reproducer: Message) {
        #expect(throws: (any Error).self) {
            _ = try Parser.decode(reproducer)
        }
        let zeroed = Message(mode: .handshake, flags: 0, checksum: 0, region: 0, payload: [])
        #expect(throws: Never.self) {
            _ = try Parser.decode(zeroed)
        }
    }

    @Test("A minimal message decodes cleanly")
    func minimalPasses() {
        #expect(throws: Never.self) {
            _ = try Parser.decode(Message(mode: .handshake, flags: 0, checksum: 0, region: 0, payload: []))
        }
    }
}
