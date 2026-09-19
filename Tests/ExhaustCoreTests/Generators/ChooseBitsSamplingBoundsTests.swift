import Testing
@testable import ExhaustCore

@Suite("Choice scaling sampling bounds")
struct ChooseBitsSamplingBoundsTests {
    @Test("Both distributions apply bounds before size scaling", arguments: UInt64(0) ... 100)
    func boundedScaling(size: UInt64) {
        for scaling in [
            ChooseBitsScaling.linear(originBits: nil, samplingWithin: 10 ... 30),
            .exponential(originBits: nil, samplingWithin: 10 ... 30),
        ] {
            let actual = Gen.applyScaling(min: 0, max: 100, tag: .uint64, scaling: scaling, size: size)
            let unbounded: ChooseBitsScaling = switch scaling.kind {
                case .linear: .linear(originBits: nil)
                case .exponential: .exponential(originBits: nil)
                case .size: .size
            }
            let expected = Gen.applyScaling(min: 10, max: 30, tag: .uint64, scaling: unbounded, size: size)
            #expect(actual == expected)
            #expect(actual.lowerBound >= 10)
            #expect(actual.upperBound <= 30)
        }
    }
}
