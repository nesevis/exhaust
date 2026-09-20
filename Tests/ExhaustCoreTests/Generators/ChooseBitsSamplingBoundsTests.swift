import Testing
@testable import ExhaustCore

@Suite("Choice scaling sampling bounds")
struct ChooseBitsSamplingBoundsTests {
    @Test("Every distribution applies sampling bounds without narrowing the declared range", arguments: UInt64(0) ... 100)
    func boundedScaling(size: UInt64) {
        for scaling in [
            ChooseBitsScaling.constant(samplingWithin: 10 ... 30),
            .linear(originBits: nil, samplingWithin: 10 ... 30),
            .exponential(originBits: nil, samplingWithin: 10 ... 30),
        ] {
            let actual = Gen.applyScaling(min: 0, max: 100, tag: .uint64, scaling: scaling, size: size)
            let unbounded: ChooseBitsScaling = switch scaling.kind {
                case .constant: .constant()
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

    @Test("Typed scaling uses an explicit constant kind only when sampling bounds require it")
    func typedScalingErasure() {
        let samplingBounds: ClosedRange<UInt64> = 10 ... 30
        #expect(SizeScaling<UInt64>.constant.erased == nil)
        #expect(
            SizeScaling<UInt64>.constant.erased(samplingWithin: samplingBounds)
                == .constant(samplingWithin: samplingBounds)
        )
        #expect(
            SizeScaling<UInt64>.linear.erased(samplingWithin: samplingBounds)
                == .linear(originBits: nil, samplingWithin: samplingBounds)
        )
        #expect(
            SizeScaling<UInt64>.linearFrom(origin: 20).erased(samplingWithin: samplingBounds)
                == .linear(originBits: 20, samplingWithin: samplingBounds)
        )
        #expect(
            SizeScaling<UInt64>.exponential.erased(samplingWithin: samplingBounds)
                == .exponential(originBits: nil, samplingWithin: samplingBounds)
        )
        #expect(
            SizeScaling<UInt64>.exponentialFrom(origin: 20).erased(samplingWithin: samplingBounds)
                == .exponential(originBits: 20, samplingWithin: samplingBounds)
        )
    }

    @Test("Constant debug descriptions distinguish declared and narrowed sampling ranges")
    func constantDebugDescription() {
        let unbounded: Generator<UInt64> = Gen.choose(
            in: 0 ... 100,
            type: UInt64.self,
            isRangeExplicit: true,
            scaling: .constant()
        )
        let bounded: Generator<UInt64> = Gen.choose(
            in: 0 ... 100,
            type: UInt64.self,
            isRangeExplicit: true,
            scaling: .constant(samplingWithin: 10 ... 30)
        )
        #expect(unbounded.debugDescription.contains("[constant]"))
        #expect(unbounded.debugDescription.contains("within sampling range") == false)
        #expect(bounded.debugDescription.contains("[constant within sampling range]"))
    }
}
