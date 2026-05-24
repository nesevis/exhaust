import ExhaustTestSupport
import Foundation
import Testing
@testable import ExhaustCore

@Suite("CrockfordBase32 Properties")
struct CrockfordBase32PropertyTests {
    @Test("encode then decode is identity for all UInt64 values")
    func roundTrip() throws {
        let gen = Gen.choose(in: UInt64.min ... UInt64.max)
        try exhaustCheck(gen, maxIterations: 500) { value in
            CrockfordBase32.decode(CrockfordBase32.encode(value)) == value
        }
    }

    @Test("Encoded output contains only valid Crockford characters")
    func validAlphabet() throws {
        let valid = CharacterSet(charactersIn: "0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        let gen = Gen.choose(in: UInt64.min ... UInt64.max)
        try exhaustCheck(gen, maxIterations: 300) { value in
            let encoded = CrockfordBase32.encode(value)
            return encoded.unicodeScalars.allSatisfy { valid.contains($0) }
        }
    }

    @Test("Encoded output is at most 13 characters")
    func maxLength() throws {
        let gen = Gen.choose(in: UInt64.min ... UInt64.max)
        try exhaustCheck(gen, maxIterations: 300) { value in
            CrockfordBase32.encode(value).count <= 13
        }
    }
}
