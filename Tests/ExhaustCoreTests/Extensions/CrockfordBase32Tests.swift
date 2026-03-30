import Testing
@testable import ExhaustCore

@Suite struct CrockfordBase32Tests {
    @Test func encodesZero() {
        #expect(CrockfordBase32.encode(0) == "0")
    }

    @Test func encodesSingleDigitValues() {
        #expect(CrockfordBase32.encode(1) == "1")
        #expect(CrockfordBase32.encode(9) == "9")
        #expect(CrockfordBase32.encode(10) == "A")
        #expect(CrockfordBase32.encode(31) == "Z")
    }

    @Test func encodesMultiDigitValues() {
        #expect(CrockfordBase32.encode(32) == "10")
        #expect(CrockfordBase32.encode(33) == "11")
        #expect(CrockfordBase32.encode(1024) == "100")
    }

    @Test func encodesUInt64Max() {
        let encoded = CrockfordBase32.encode(UInt64.max)
        #expect(encoded.count <= 13)
        #expect(CrockfordBase32.decode(encoded) == UInt64.max)
    }

    @Test func roundTripsArbitraryValues() {
        let values: [UInt64] = [
            0, 1, 31, 32, 255, 256, 1023, 1024,
            UInt64.max / 2, UInt64.max - 1, UInt64.max,
        ]
        for value in values {
            let encoded = CrockfordBase32.encode(value)
            #expect(CrockfordBase32.decode(encoded) == value, "Round-trip failed for \(value)")
        }
    }

    @Test func roundTripsPowersOfTwo() {
        for exponent in 0 ..< 64 {
            let value: UInt64 = 1 << exponent
            let encoded = CrockfordBase32.encode(value)
            #expect(CrockfordBase32.decode(encoded) == value, "Round-trip failed for 2^\(exponent)")
        }
    }

    @Test func decodesLowercase() {
        let upper = CrockfordBase32.encode(123_456_789)
        let lower = upper.lowercased()
        #expect(CrockfordBase32.decode(lower) == 123_456_789)
    }

    @Test func decodesMixedCase() {
        let encoded = CrockfordBase32.encode(999_999)
        let mixed = String(encoded.enumerated().map { index, char in
            index.isMultiple(of: 2) ? Character(char.lowercased()) : char
        })
        #expect(CrockfordBase32.decode(mixed) == 999_999)
    }

    @Test func decodesAmbiguousCharacters() {
        // O → 0, I → 1, L → 1
        #expect(CrockfordBase32.decode("O") == CrockfordBase32.decode("0"))
        #expect(CrockfordBase32.decode("I") == CrockfordBase32.decode("1"))
        #expect(CrockfordBase32.decode("L") == CrockfordBase32.decode("1"))
        #expect(CrockfordBase32.decode("l") == CrockfordBase32.decode("1"))
        #expect(CrockfordBase32.decode("o") == CrockfordBase32.decode("0"))

        // Multi-character ambiguity
        #expect(CrockfordBase32.decode("OIL") == CrockfordBase32.decode("011"))
    }

    @Test func rejectsInvalidCharacters() {
        #expect(CrockfordBase32.decode("U") == nil, "U is excluded from Crockford alphabet")
        #expect(CrockfordBase32.decode("u") == nil)
        #expect(CrockfordBase32.decode("!") == nil)
        #expect(CrockfordBase32.decode(" ") == nil)
        #expect(CrockfordBase32.decode("ABC!DEF") == nil)
    }

    @Test func rejectsEmptyString() {
        #expect(CrockfordBase32.decode("") == nil)
    }

    @Test func rejectsOverflow() {
        // UInt64.max encodes to 13 characters. A 14-character string overflows.
        let maxEncoded = CrockfordBase32.encode(UInt64.max)
        #expect(maxEncoded.count == 13)

        // Prepending a non-zero digit causes overflow
        #expect(CrockfordBase32.decode("1" + maxEncoded) == nil)

        // A string of all Z's (max digit) that's too long
        let tooLong = String(repeating: "Z", count: 14)
        #expect(CrockfordBase32.decode(tooLong) == nil)
    }

    @Test func encodedOutputContainsOnlyValidCharacters() {
        let validCharacters = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        let values: [UInt64] = [0, 1, 42, 12345, UInt64.max]
        for value in values {
            let encoded = CrockfordBase32.encode(value)
            for character in encoded {
                #expect(validCharacters.contains(character), "Invalid character '\(character)' in encoding of \(value)")
            }
        }
    }
}
