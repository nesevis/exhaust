//
//  SIMDGeneratorTests.swift
//  Exhaust
//

import Exhaust
import Testing

@Suite("SIMD Generators")
struct SIMDGeneratorTests {
    @Test("simd2 with explicit range")
    func simd2ExplicitRange() {
        #expect(#examine(.simd2(.float(in: 0 ... 1)), .samples(50)).passed)
    }

    @Test("simd2 per-lane")
    func simd2PerLane() {
        #expect(#examine(.simd2(.float(in: 0 ... 1), .float(in: -1 ... 0)), .samples(50)).passed)
    }

    @Test("simd3 with explicit range")
    func simd3ExplicitRange() {
        #expect(#examine(.simd3(.double(in: -1 ... 1)), .samples(50)).passed)
    }

    @Test("simd4 with explicit range")
    func simd4ExplicitRange() {
        #expect(#examine(.simd4(.float(in: 0 ... 1)), .samples(50)).passed)
    }

    @Test("simd4 per-lane")
    func simd4PerLane() {
        #expect(#examine(
            .simd4(.float(in: 0 ... 1), .float(in: 1 ... 2), .float(in: 2 ... 3), .float(in: 3 ... 4)),
            .samples(50)
        ).passed)
    }

    @Test("simd8 with explicit range")
    func simd8ExplicitRange() {
        #expect(#examine(.simd8(.int32(in: 0 ... 255)), .samples(50)).passed)
    }

    @Test("simd16 with explicit range")
    func simd16ExplicitRange() {
        #expect(#examine(.simd16(.uint8(in: 0 ... 127)), .samples(50)).passed)
    }

    @Test("simd32 with explicit range")
    func simd32ExplicitRange() {
        #expect(#examine(.simd32(.uint8(in: 0 ... 127)), .samples(30)).passed)
    }

    @Test("simd64 with explicit range")
    func simd64ExplicitRange() {
        #expect(#examine(.simd64(.uint8(in: 0 ... 127)), .samples(30)).passed)
    }

    // MARK: - Size-scaled scalars (multi-node lanes)

    @Test("simd2 with size-scaled uint8")
    func simd2SizeScaled() {
        #expect(#examine(.simd2(.uint8()), .samples(50)).passed)
    }

    @Test("simd4 with size-scaled int32")
    func simd4SizeScaledInt32() {
        #expect(#examine(.simd4(.int32()), .samples(50)).passed)
    }
}
