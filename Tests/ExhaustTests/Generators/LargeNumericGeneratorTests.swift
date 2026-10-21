//
//  LargeNumericGeneratorTests.swift
//  Exhaust
//

import Exhaust
import Testing

@Suite("Int128 / UInt128 Generators")
struct LargeNumericGeneratorTests {
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Both halves of UInt128 are populated")
    func unsignedHighBits() throws {
        let values = try #example(.uint128(), count: 100, seed: 42)
        #expect(values.count == 100)
        #expect(values.contains { $0 >> 64 > 0 })
        #expect(values.contains { UInt64(truncatingIfNeeded: $0) > 0 })
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Int128 generates negative values")
    func int128Negatives() {
        let gen = #gen(.int128())

        let counterExample = #exhaust(gen, .suppress(.issueReporting)) { value in
            value >= 0
        }

        #expect(counterExample != nil)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("UInt128 validates with #examine")
    func examineUInt128() {
        let gen = #gen(.uint128())
        let report = #examine(gen, .samples(50)) { $0 == $1 }
        #expect(report.passed)
        #expect(report.valuesGenerated == 50)
        #expect(report.replayDeterminismSuccesses == 50)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Int128 validates with #examine")
    func examineInt128() {
        let gen = #gen(.int128())
        let report = #examine(gen, .samples(50)) { $0 == $1 }
        #expect(report.passed)
        #expect(report.valuesGenerated == 50)
        #expect(report.replayDeterminismSuccesses == 50)
    }
}
