//
//  Xoshiro.swift
//  Exhaust
//
//  Created by Chris Kolbu on 27/7/2025.
//

/// The magical 3-in-1 PRNG
@_spi(ExhaustInternal) public struct Xoshiro256: ~Copyable {
    @_spi(ExhaustInternal) public typealias StateType = (UInt64, UInt64, UInt64, UInt64)

    @_spi(ExhaustInternal) public let seed: UInt64
    private var state: StateType

    /// Read-only access to internal state for explicit cloning.
    @_spi(ExhaustInternal) public var currentState: StateType { state }

    /// Jump polynomial for 2^128 steps
    private static let jumpPoly: [UInt64] = [
        0x180E_C6D3_3CFD_0ABA, 0xD5A6_1266_F0C9_392C,
        0xA958_2618_E03F_C9AA, 0x39AB_DC45_29B1_661C,
    ]

    /// Long jump polynomial for 2^192 steps
    private static let longJumpPoly: [UInt64] = [
        0x76E1_5D3E_FEFD_CBBF, 0xC500_4E44_1C52_2FB3,
        0x7771_0069_854E_E241, 0x3910_9BB0_2ACB_E635,
    ]

    @_spi(ExhaustInternal) public init() {
        var rng = SystemRandomNumberGenerator()
        self.init(seed: rng.next())
    }

    @_spi(ExhaustInternal) public init(seed: UInt64) {
        self.seed = seed
        // SplitMix64 guarantees we won't get all zeros
        var splitmix = SplitMix64(seed: seed)
        state = (
            splitmix.next(),
            splitmix.next(),
            splitmix.next(),
            splitmix.next(),
        )
    }

    /// Construct from explicit state for deliberate cloning.
    @_spi(ExhaustInternal) public init(seed: UInt64, state: StateType) {
        self.seed = seed
        self.state = state
    }

    @_spi(ExhaustInternal) public mutating func next() -> UInt64 {
        let result = rotateLeft(state.1 &* 5, 7) &* 9
        let t = state.1 &<< 17

        state.2 ^= state.0
        state.3 ^= state.1
        state.1 ^= state.2
        state.0 ^= state.3
        state.2 ^= t
        state.3 = rotateLeft(state.3, 45)

        return result
    }

    /// Returns a uniformly distributed random integer in `[0, upperBound)`.
    ///
    /// Uses multiply-high with rejection sampling to avoid modulo bias.
    /// This follows Lemire's approach and avoids `%` on the hot path.
    @inline(__always)
    @_spi(ExhaustInternal) public mutating func next(upperBound: UInt64) -> UInt64 {
        precondition(upperBound > 0, "upperBound must be > 0")

        // Power-of-two bounds can be sampled with a single mask.
        if upperBound & (upperBound &- 1) == 0 {
            return next() & (upperBound &- 1)
        }

        // Equivalent to 2^64 % upperBound using wrapping arithmetic.
        let threshold = (0 &- upperBound) % upperBound
        while true {
            let product = next().multipliedFullWidth(by: upperBound)
            if product.low >= threshold {
                return product.high
            }
        }
    }

    /// Returns a random integer in `range`.
    ///
    /// This is intentionally separate from `next(upperBound:)` so callers can
    /// choose between stdlib range behavior and fast bounded sampling.
    @inline(__always)
    @_spi(ExhaustInternal) public mutating func next(in range: ClosedRange<UInt64>) -> UInt64 {
        let width = range.upperBound &- range.lowerBound
        if width == UInt64.max { return next() }
        return range.lowerBound &+ next(upperBound: width &+ 1)
    }

    @inline(__always)
    private func rotateLeft(_ x: UInt64, _ k: Int) -> UInt64 {
        (x &<< k) | (x &>> (64 - k))
    }

    /// Jump ahead 2^128 steps for parallel streams
    @_spi(ExhaustInternal) public mutating func jump() {
        var s0: UInt64 = 0
        var s1: UInt64 = 0
        var s2: UInt64 = 0
        var s3: UInt64 = 0

        for jump in Self.jumpPoly {
            for b in 0 ..< 64 {
                if (jump & (1 << b)) != 0 {
                    s0 ^= state.0
                    s1 ^= state.1
                    s2 ^= state.2
                    s3 ^= state.3
                }
                _ = next()
            }
        }

        state = (s0, s1, s2, s3)
    }

    /// Create an independent stream
    @_spi(ExhaustInternal) public func spawned(streamID: UInt64) -> Xoshiro256 {
        var newGen = Xoshiro256(seed: seed, state: state)
        // Use streamID to determine number of jumps
        for _ in 0 ..< (streamID & 0xFF) {
            newGen.jump()
        }
        return newGen
    }
}

/// SplitMix64 for initial seeding of Xoshiro
private struct SplitMix64 {
    private var state: UInt64

    let incrementConstant: UInt64 = 0x9E37_79B9_7F4A_7C15
    let mixingConstant1: UInt64 = 0xBF58_476D_1CE4_E5B9
    let mixingConstant2: UInt64 = 0x94D0_49BB_1331_11EB

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ incrementConstant
        var z = state
        z = (z ^ (z &>> 30)) &* mixingConstant1
        z = (z ^ (z &>> 27)) &* mixingConstant2
        return z ^ (z &>> 31)
    }
}
