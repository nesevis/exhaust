//
//  UUIDGeneratorTests.swift
//  Exhaust
//

import Foundation
import Testing
@testable import Exhaust

@Suite("UUID Generator")
struct UUIDGeneratorTests {
    @Test("Generated UUIDs are valid v4")
    func validV4() {
        let gen = #gen(.uuid())

        let counterExample = #exhaust(gen) { uuid in
            let str = uuid.uuidString
            // Version nibble (character at index 14) must be '4'
            let versionChar = str[str.index(str.startIndex, offsetBy: 14)]
            guard versionChar == "4" else { return false }
            // Variant nibble (character at index 19) must be 8, 9, A, or B
            let variantChar = str[str.index(str.startIndex, offsetBy: 19)]
            return "89AB".contains(variantChar)
        }

        #expect(counterExample == nil)
    }

    @Test("Generated UUIDs are unique", .disabled())
    func uniqueness() {
        let gen = #gen(.uuid(), .uuid())

        let counterExample = #exhaust(gen, .maxIterations(1000)) { a, b in
            a != b
        }

        #expect(counterExample == nil)
    }

    @Test("UUID round-trips through string")
    func stringRoundTrip() {
        let gen = #gen(.uuid())

        let counterExample = #exhaust(gen) { uuid in
            let str = uuid.uuidString
            guard let parsed = UUID(uuidString: str) else { return false }
            return parsed == uuid
        }

        #expect(counterExample == nil)
    }

    @Test("UUID generator validates with #examine")
    func examine() {
        let gen = #gen(.uuid())
        #examine(gen, samples: 50)
    }
}
