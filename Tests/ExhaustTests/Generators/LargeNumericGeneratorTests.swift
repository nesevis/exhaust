//
//  LargeNumericGeneratorTests.swift
//  Exhaust
//

import Testing
@testable import Exhaust

@Suite("Int128 / UInt128 Generators")
struct LargeNumericGeneratorTests {
    @Test("UInt128 round-trips through bit pattern")
    func uint128RoundTrip() {
        let gen = #gen(.uint128())

        let counterExample = #exhaust(gen) { value in
            let high = UInt64(truncatingIfNeeded: value >> 64)
            let low = UInt64(truncatingIfNeeded: value)
            let reconstructed = UInt128(high) << 64 | UInt128(low)
            return reconstructed == value
        }

        #expect(counterExample == nil)
    }

    @Test("Int128 round-trips through bit pattern")
    func int128RoundTrip() {
        let gen = #gen(.int128())

        let counterExample = #exhaust(gen) { value in
            let bits = UInt128(bitPattern: value)
            let reconstructed = Int128(bitPattern: bits)
            return reconstructed == value
        }

        #expect(counterExample == nil)
    }

    @Test("Int128 generates negative values")
    func int128Negatives() {
        let gen = #gen(.int128())

        let counterExample = #exhaust(gen, .samplingBudget(200), .suppressIssueReporting) { value in
            value >= 0
        }

        #expect(counterExample != nil)
    }

    @Test("UInt128 validates with #examine")
    func examineUInt128() {
        let gen = #gen(.uint128())
        #examine(gen, samples: 50)
    }

    @Test("Int128 validates with #examine")
    func examineInt128() {
        let gen = #gen(.int128())
        #examine(gen, samples: 50)
    }
}
