import Testing
@testable import ExhaustCore

@Suite("Crockford Base32 Replay")
struct CrockfordBase32ReplayTests {
    @Test func replayWithBase32EncodedSeed() throws {
        // Encode a known seed and verify the round-trip
        let originalSeed: UInt64 = 12345
        let encoded = CrockfordBase32.encode(originalSeed)
        let decoded = try #require(CrockfordBase32.decode(encoded))
        #expect(decoded == originalSeed, "Round-trip through Base32 should preserve the seed")
    }

    @Test func replaySeedStringLiteralResolvesToDecodedValue() {
        let encoded = CrockfordBase32.encode(42)
        let decoded = CrockfordBase32.decode(encoded)
        #expect(decoded == 42)
    }
}
