import Testing
@testable import ExhaustCore

struct ReplaySeedTests {
    @Test func encodesZero() {
        #expect(ReplaySeed.encode(0) == "0")
    }

    @Test func encodesSingleDigitValues() {
        #expect(ReplaySeed.encode(1) == "1")
        #expect(ReplaySeed.encode(9) == "9")
        #expect(ReplaySeed.encode(10) == "A")
        #expect(ReplaySeed.encode(31) == "Z")
    }

    @Test func encodesMultiDigitValues() {
        #expect(ReplaySeed.encode(32) == "10")
        #expect(ReplaySeed.encode(33) == "11")
        #expect(ReplaySeed.encode(1024) == "100")
    }

    @Test func encodesUInt64Max() {
        let encoded = ReplaySeed.encode(UInt64.max)
        #expect(encoded.count <= 13)
        #expect(ReplaySeed.decode(encoded) == UInt64.max)
    }

    @Test func roundTripsArbitraryValues() {
        let values: [UInt64] = [
            0, 1, 31, 32, 255, 256, 1023, 1024,
            UInt64.max / 2, UInt64.max - 1, UInt64.max,
        ]
        for value in values {
            let encoded = ReplaySeed.encode(value)
            #expect(ReplaySeed.decode(encoded) == value, "Round-trip failed for \(value)")
        }
    }

    @Test func roundTripsPowersOfTwo() {
        for exponent in 0 ..< 64 {
            let value: UInt64 = 1 << exponent
            let encoded = ReplaySeed.encode(value)
            #expect(ReplaySeed.decode(encoded) == value, "Round-trip failed for 2^\(exponent)")
        }
    }

    @Test func decodesLowercase() {
        let upper = ReplaySeed.encode(123_456_789)
        let lower = upper.lowercased()
        #expect(ReplaySeed.decode(lower) == 123_456_789)
    }

    @Test func decodesMixedCase() {
        let encoded = ReplaySeed.encode(999_999)
        let mixed = String(encoded.enumerated().map { index, char in
            index.isMultiple(of: 2) ? Character(char.lowercased()) : char
        })
        #expect(ReplaySeed.decode(mixed) == 999_999)
    }

    @Test func decodesAmbiguousCharacters() {
        // O → 0, I → 1, L → 1
        #expect(ReplaySeed.decode("O") == ReplaySeed.decode("0"))
        #expect(ReplaySeed.decode("I") == ReplaySeed.decode("1"))
        #expect(ReplaySeed.decode("L") == ReplaySeed.decode("1"))
        #expect(ReplaySeed.decode("l") == ReplaySeed.decode("1"))
        #expect(ReplaySeed.decode("o") == ReplaySeed.decode("0"))

        // Multi-character ambiguity
        #expect(ReplaySeed.decode("OIL") == ReplaySeed.decode("011"))
    }

    @Test func rejectsInvalidCharacters() {
        #expect(ReplaySeed.decode("U") == nil, "U is excluded from Crockford alphabet")
        #expect(ReplaySeed.decode("u") == nil)
        #expect(ReplaySeed.decode("!") == nil)
        #expect(ReplaySeed.decode(" ") == nil)
        #expect(ReplaySeed.decode("ABC!DEF") == nil)
    }

    @Test func rejectsEmptyString() {
        #expect(ReplaySeed.decode("") == nil)
    }

    @Test func rejectsOverflow() {
        // UInt64.max encodes to 13 characters. A 14-character string overflows.
        let maxEncoded = ReplaySeed.encode(UInt64.max)
        #expect(maxEncoded.count == 13)

        // Prepending a non-zero digit causes overflow
        #expect(ReplaySeed.decode("1" + maxEncoded) == nil)

        // A string of all Z's (max digit) that's too long
        let tooLong = String(repeating: "Z", count: 14)
        #expect(ReplaySeed.decode(tooLong) == nil)
    }

    @Test func encodedOutputContainsOnlyValidCharacters() {
        let validCharacters = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        let values: [UInt64] = [0, 1, 42, 12345, UInt64.max]
        for value in values {
            let encoded = ReplaySeed.encode(value)
            for character in encoded {
                #expect(validCharacters.contains(character), "Invalid character '\(character)' in encoding of \(value)")
            }
        }
    }

    @Test func decodesSuffixlessSeedWithNilIteration() {
        let decoded = ReplaySeed.decodeWithIteration("1A")
        #expect(decoded?.seed == ReplaySeed.decode("1A"))
        #expect(decoded?.iteration == nil)
    }

    @Test func decodesOneBasedIteration() {
        let decoded = ReplaySeed.decodeWithIteration("1A-7")
        #expect(decoded?.seed == ReplaySeed.decode("1A"))
        #expect(decoded?.iteration == 7)
    }

    @Test func rejectsIterationZeroRatherThanUnderflowing() {
        // The wire format is 1-based; replay recovers the start index as `iteration - 1`,
        // so iteration 0 must be rejected here instead of trapping on `UInt64(-1)`.
        #expect(ReplaySeed.decodeWithIteration("1A-0") == nil)
    }

    @Test func rejectsNegativeIteration() {
        #expect(ReplaySeed.decodeWithIteration("1A--1") == nil)
    }
}
