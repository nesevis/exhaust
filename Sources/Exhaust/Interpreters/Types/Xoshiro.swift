//
//  Xoshiro.swift
//  Exhaust
//
//  Created by Chris Kolbu on 27/7/2025.
//

// The magical 3-in-1 PRNG
public struct Xoshiro256: RandomNumberGenerator {
    public typealias StateType = (UInt64, UInt64, UInt64, UInt64)
    
    public let seed: UInt64
    private var state: StateType
    
    // Jump polynomial for 2^128 steps
    private static let jumpPoly: [UInt64] = [
        0x180ec6d33cfd0aba, 0xd5a61266f0c9392c,
        0xa9582618e03fc9aa, 0x39abdc4529b1661c
    ]
    
    // Long jump polynomial for 2^192 steps
    private static let longJumpPoly: [UInt64] = [
        0x76e15d3efefdcbbf, 0xc5004e441c522fb3,
        0x77710069854ee241, 0x39109bb02acbe635
    ]
    
    public init() {
        var rng = SystemRandomNumberGenerator()
        self.init(seed: rng.next())
    }

    public init(seed: UInt64) {
        self.seed = seed
        // SplitMix64 guarantees we won't get all zeros
        var splitmix = SplitMix64(seed: seed)
        self.state = (
            splitmix.next(),
            splitmix.next(),
            splitmix.next(),
            splitmix.next()
        )
    }
    
    public mutating func next() -> UInt64 {
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

    @inline(__always)
    private func rotateLeft(_ x: UInt64, _ k: Int) -> UInt64 {
        return (x &<< k) | (x &>> (64 - k))
    }
    
    // Jump ahead 2^128 steps for parallel streams
    public mutating func jump() {
        var s0: UInt64 = 0
        var s1: UInt64 = 0
        var s2: UInt64 = 0
        var s3: UInt64 = 0
        
        for jump in Self.jumpPoly {
            for b in 0..<64 {
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
    
    // Create an independent stream
    public func spawned(streamID: UInt64) -> Xoshiro256 {
        var newGen = self
        // Use streamID to determine number of jumps
        for _ in 0..<(streamID & 0xFF) {
            newGen.jump()
        }
        return newGen
    }
}

// SplitMix64 for initial seeding of Xoshiro
private struct SplitMix64 {
    private var state: UInt64
    
    let incrementConstant: UInt64 = 0x9e3779b97f4a7c15
    let mixingConstant1: UInt64 = 0xbf58476d1ce4e5b9
    let mixingConstant2: UInt64 = 0x94d049bb133111eb

    init(seed: UInt64) {
        self.state = seed
    }
    
    mutating func next() -> UInt64 {
        state = state &+ incrementConstant
        var z = state
        z = (z ^ (z &>> 30)) &* mixingConstant1
        z = (z ^ (z &>> 27)) &* mixingConstant2
        return z ^ (z &>> 31)
    }
}
