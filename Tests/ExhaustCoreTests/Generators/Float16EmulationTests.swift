import Testing
@testable import ExhaustCore

#if arch(arm64) || arch(arm64_32)
    @Suite("Float16 Emulation")
    struct Float16EmulationTests {
        @Test("Emulation round-trips match actual Float16")
        func emulationRoundTrip() {
            let testValues: [Float16] = [
                0, -0.0, 1.0, -1.0, 0.5, -0.5,
                Float16.greatestFiniteMagnitude,
                -Float16.greatestFiniteMagnitude,
                Float16.leastNonzeroMagnitude,
                Float16.leastNormalMagnitude,
                42.0, -100.0,
            ]
            for value in testValues {
                let encoded = value.bitPattern64
                let emulated = Float16Emulation.doubleValue(fromEncoded: encoded)
                #expect(
                    emulated == Double(value),
                    "Emulation mismatch for \(value): emulated=\(emulated), actual=\(Double(value))"
                )

                let reencoded = Float16Emulation.encodedBitPattern(from: Double(value))
                #expect(
                    reencoded == encoded,
                    "Re-encoding mismatch for \(value): reencoded=\(reencoded), actual=\(encoded)"
                )
            }
        }
    }
#endif
