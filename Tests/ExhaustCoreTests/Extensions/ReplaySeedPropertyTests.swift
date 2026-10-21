import ExhaustTestSupport
import Foundation
import Testing
@testable import ExhaustCore

@Suite("ReplaySeed properties")
struct ReplaySeedPropertyTests {
    @Test("Encoding is bounded Crockford text that decodes to the original word")
    func encodingContract() throws {
        let alphabet = CharacterSet(charactersIn: "0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        try exhaustCheck(Gen.choose(in: UInt64.min ... UInt64.max), maxIterations: 500) { value in
            let encoded = ReplaySeed.encode(value)
            return ReplaySeed.decode(encoded) == value
                && (1 ... 13).contains(encoded.count)
                && encoded.unicodeScalars.allSatisfy { alphabet.contains($0) }
        }
    }
}
