import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Redistribution Conservation Properties")
struct RedistributionConservationPropertyTests {
    @Test("Signed integer redistribution conserves total value for arbitrary pairs and deltas")
    func signedConservation() throws {
        let pairGen = Gen.zip(
            Gen.choose(in: Int64(-1000) ... 1000),
            Gen.choose(in: Int64(-1000) ... 1000)
        ).map { (pair: (Int64, Int64)) in pair }

        try exhaustCheck(pairGen, maxIterations: 300) { sourceValue, sinkValue in
            guard sourceValue != sinkValue else { return true }

            let source = ChoiceValue(sourceValue, tag: .int64)
            let sink = ChoiceValue(sinkValue, tag: .int64)

            guard let context = GraphRedistributionEncoder.makeMixedRedistributionContext(
                sourceChoice: source,
                sinkChoice: sink,
                sourceValidRange: nil as ClosedRange<UInt64>?,
                sourceIsRangeExplicit: false
            ) else {
                return true
            }

            let originalTotal = sourceValue + sinkValue
            for delta: UInt64 in 1 ... min(context.distanceInSteps, 20) {
                guard let (newSource, newSink) = GraphRedistributionEncoder.mixedRedistributedPairChoices(
                    sourceChoice: source,
                    sinkChoice: sink,
                    delta: delta,
                    context: context
                ) else {
                    continue
                }
                let newTotal = newSource.decodedSignedValue + newSink.decodedSignedValue
                if newTotal != originalTotal { return false }
            }
            return true
        }
    }

    @Test("Unsigned integer redistribution conserves total value for arbitrary pairs and deltas")
    func unsignedConservation() throws {
        let pairGen = Gen.zip(
            Gen.choose(in: UInt64(1) ... 1000),
            Gen.choose(in: UInt64(0) ... 999)
        ).map { (pair: (UInt64, UInt64)) in pair }

        try exhaustCheck(pairGen, maxIterations: 300) { sourceValue, sinkValue in
            guard sourceValue != sinkValue else { return true }
            guard sourceValue > sinkValue else { return true }

            let source = ChoiceValue(sourceValue, tag: .uint64)
            let sink = ChoiceValue(sinkValue, tag: .uint64)

            guard let context = GraphRedistributionEncoder.makeMixedRedistributionContext(
                sourceChoice: source,
                sinkChoice: sink,
                sourceValidRange: nil as ClosedRange<UInt64>?,
                sourceIsRangeExplicit: false
            ) else {
                return true
            }

            let originalTotal = sourceValue + sinkValue
            for delta: UInt64 in 1 ... min(context.distanceInSteps, 20) {
                guard let (newSource, newSink) = GraphRedistributionEncoder.mixedRedistributedPairChoices(
                    sourceChoice: source,
                    sinkChoice: sink,
                    delta: delta,
                    context: context
                ) else {
                    continue
                }
                let newTotal = newSource.bitPattern64 + newSink.bitPattern64
                if newTotal != originalTotal { return false }
            }
            return true
        }
    }

    @Test("Redistribution source moves toward semantic zero")
    func sourceMovesTowardZero() throws {
        let pairGen = Gen.zip(
            Gen.choose(in: Int64(1) ... 500),
            Gen.choose(in: Int64(-500) ... -1)
        ).map { (pair: (Int64, Int64)) in pair }

        try exhaustCheck(pairGen, maxIterations: 200) { sourceValue, sinkValue in
            let source = ChoiceValue(sourceValue, tag: .int64)
            let sink = ChoiceValue(sinkValue, tag: .int64)

            guard let context = GraphRedistributionEncoder.makeMixedRedistributionContext(
                sourceChoice: source,
                sinkChoice: sink,
                sourceValidRange: nil as ClosedRange<UInt64>?,
                sourceIsRangeExplicit: false
            ) else {
                return true
            }

            guard let (newSource, _) = GraphRedistributionEncoder.mixedRedistributedPairChoices(
                sourceChoice: source,
                sinkChoice: sink,
                delta: 1,
                context: context
            ) else {
                return true
            }

            let originalDistance = abs(sourceValue)
            let newDistance = abs(newSource.decodedSignedValue)
            return newDistance <= originalDistance
        }
    }
}
