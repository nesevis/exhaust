import Testing
@testable import ExhaustCore

@Suite("Crockford Base32 Replay")
struct ReplaySeedReplayTests {
    @Test func replayWithBase32EncodedSeed() throws {
        // Encode a known seed and verify the round-trip
        let originalSeed: UInt64 = 12345
        let encoded = ReplaySeed.encode(originalSeed)
        let decoded = try #require(ReplaySeed.decode(encoded))
        #expect(decoded == originalSeed, "Round-trip through Base32 should preserve the seed")
    }

    @Test func replaySeedStringLiteralResolvesToDecodedValue() {
        let encoded = ReplaySeed.encode(42)
        let decoded = ReplaySeed.decode(encoded)
        #expect(decoded == 42)
    }
}
