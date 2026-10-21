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
        #expect(Fixture.reproducerA.mode != Fixture.reproducerB.mode)
        #expect(Fixture.reproducerA != Fixture.reproducerB)
    }

    @Test("A minimal message decodes cleanly")
    func minimalPasses() {
        #expect(throws: Never.self) {
            _ = try Parser.decode(Message(mode: .handshake, flags: 0, checksum: 0, region: 0, payload: []))
        }
    }
}
