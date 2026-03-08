//
//  SIMDGeneratorTests.swift
//  Exhaust
//

import Testing
@testable import Exhaust

@Suite("SIMD Generators")
struct SIMDGeneratorTests {
    @Test("simd2 with explicit range")
    func simd2ExplicitRange() {
        #examine(.simd2(.float(in: 0 ... 1)), samples: 50)
    }

    @Test("simd2 per-lane")
    func simd2PerLane() {
        #examine(.simd2(.float(in: 0 ... 1), .float(in: -1 ... 0)), samples: 50)
    }

    @Test("simd3 with explicit range")
    func simd3ExplicitRange() {
        #examine(.simd3(.double(in: -1 ... 1)), samples: 50)
    }

    @Test("simd4 with explicit range")
    func simd4ExplicitRange() {
        #examine(.simd4(.float(in: 0 ... 1)), samples: 50)
    }

    @Test("simd4 per-lane")
    func simd4PerLane() {
        #examine(
            .simd4(.float(in: 0 ... 1), .float(in: 1 ... 2), .float(in: 2 ... 3), .float(in: 3 ... 4)),
            samples: 50,
        )
    }

    @Test("simd8 with explicit range")
    func simd8ExplicitRange() {
        #examine(.simd8(.int32(in: 0 ... 255)), samples: 50)
    }

    @Test("simd16 with explicit range")
    func simd16ExplicitRange() {
        #examine(.simd16(.uint8(in: 0 ... 127)), samples: 50)
    }

    @Test("simd32 with explicit range")
    func simd32ExplicitRange() {
        #examine(.simd32(.uint8(in: 0 ... 127)), samples: 30)
    }

    @Test("simd64 with explicit range")
    func simd64ExplicitRange() {
        #examine(.simd64(.uint8(in: 0 ... 127)), samples: 30)
    }
}
