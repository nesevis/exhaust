//
//  SizeScalingDistributionTests.swift
//  ExhaustCoreTests
//
//  Statistical tests for ``SizeScaling`` that verify bare `.linear` and
//  `.exponential` anchor distributions at the type's semantically simplest
//  value rather than the bit-pattern lower bound. Also guards against the
//  `scaledDistance` overflow regression that collapsed even-sized linear
//  ranges to `[0, 0]`.
//

import ExhaustCore
import Foundation
import Testing

@Suite("Size Scaling — Distribution")
struct SizeScalingDistributionTests {
    // MARK: - Signed integers anchor at zero

    @Test("Int linear at small size clusters symmetrically around zero")
    func intLinearCentersOnZero() throws {
        let samples = sample(
            Gen.resize(30, Gen.choose(in: Int.min ... Int.max, scaling: .linear)),
            count: 400,
            seed: 1
        )
        let sum = samples.reduce(0.0) { $0 + Double($1) }
        let meanRatio = sum / Double(samples.count) / Double(Int.max)
        let (negatives, positives) = signCounts(samples)

        #expect(abs(meanRatio) < 0.1, "Mean should be near zero, got ratio \(meanRatio)")
        #expect(negatives > samples.count / 4, "Expected substantial negatives, got \(negatives)")
        #expect(positives > samples.count / 4, "Expected substantial positives, got \(positives)")

        let maxMagnitude = samples.map { abs(Double($0)) }.max() ?? 0
        #expect(
            maxMagnitude < Double(Int.max) / 2,
            "At size 30, samples should not reach magnitudes near Int.max, got \(maxMagnitude)"
        )
    }

    @Test("Int exponential at small size is tighter than linear")
    func intExponentialTighterThanLinear() throws {
        let linearSamples = sample(
            Gen.resize(20, Gen.choose(in: Int.min ... Int.max, scaling: .linear)),
            count: 400,
            seed: 2
        )
        let exponentialSamples = sample(
            Gen.resize(20, Gen.choose(in: Int.min ... Int.max, scaling: .exponential)),
            count: 400,
            seed: 2
        )

        let linearMedian = medianMagnitude(linearSamples)
        let exponentialMedian = medianMagnitude(exponentialSamples)

        #expect(
            exponentialMedian < linearMedian,
            "Exponential should be tighter at small sizes. Linear median \(linearMedian), exponential median \(exponentialMedian)"
        )
    }

    @Test("Int linear at size 100 spans the full range")
    func intLinearReachesFullRangeAtSize100() throws {
        let samples = sample(
            Gen.resize(100, Gen.choose(in: Int.min ... Int.max, scaling: .linear)),
            count: 400,
            seed: 3
        )
        let negativeRatio = Double(samples.filter { $0 < 0 }.count) / Double(samples.count)
        #expect(negativeRatio > 0.35 && negativeRatio < 0.65, "Expected balanced signs at size 100, got \(negativeRatio)")

        let largePositive = samples.contains { $0 > Int.max / 2 }
        let largeNegative = samples.contains { $0 < Int.min / 2 }
        #expect(largePositive, "At size 100 samples should reach upper half of Int range")
        #expect(largeNegative, "At size 100 samples should reach lower half of Int range")
    }

    // MARK: - Floats anchor at zero

    @Test("Double linear at small size clusters symmetrically around zero")
    func doubleLinearCentersOnZero() throws {
        let range = -Double.greatestFiniteMagnitude ... Double.greatestFiniteMagnitude
        let samples = sample(
            Gen.resize(25, Gen.choose(in: range, scaling: .linear)),
            count: 400,
            seed: 4
        )
        let finiteSamples = samples.filter { $0.isFinite }
        let (negatives, positives) = signCountsDouble(finiteSamples)

        #expect(negatives > samples.count / 4, "Expected substantial negatives, got \(negatives)")
        #expect(positives > samples.count / 4, "Expected substantial positives, got \(positives)")

        let maxMagnitude = finiteSamples.map(abs).max() ?? 0
        #expect(
            maxMagnitude < Double.greatestFiniteMagnitude / 2,
            "At size 25, Double samples should not reach magnitudes near greatestFiniteMagnitude"
        )
    }

    // MARK: - Unsigned integers anchor at the lower bound

    @Test("UInt64 linear at small size stays near the lower bound")
    func uint64LinearAnchorsAtLowerBound() throws {
        let samples = sample(
            Gen.resize(10, Gen.choose(in: UInt64.min ... UInt64.max, scaling: .linear)),
            count: 400,
            seed: 5
        )
        let maxValue = samples.max() ?? 0
        #expect(
            maxValue < UInt64.max / 4,
            "At size 10, UInt64 linear should stay in the lower quarter, max was \(maxValue)"
        )
    }

    // MARK: - Ranges entirely above or below zero

    @Test("Linear on range above zero grows upward from lower bound")
    func linearOnPositiveRangeGrowsUpward() throws {
        let range: ClosedRange<Int> = 100 ... 1_000_000
        let samples = sample(
            Gen.resize(10, Gen.choose(in: range, scaling: .linear)),
            count: 400,
            seed: 6
        )
        #expect(samples.allSatisfy { range.contains($0) }, "All samples must stay in declared range")
        let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
        #expect(
            mean < 500_000,
            "At size 10 on positive range, mean should stay near lower bound, got \(mean)"
        )
    }

    @Test("Linear on range below zero grows downward from upper bound")
    func linearOnNegativeRangeGrowsDownward() throws {
        let range: ClosedRange<Int> = -1_000_000 ... -100
        let samples = sample(
            Gen.resize(10, Gen.choose(in: range, scaling: .linear)),
            count: 400,
            seed: 7
        )
        #expect(samples.allSatisfy { range.contains($0) }, "All samples must stay in declared range")
        let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
        #expect(
            mean > -500_000,
            "At size 10 on negative range, mean should stay near upper bound, got \(mean)"
        )
    }

    // MARK: - Regression: scaledDistance overflow

    @Test("Linear effective range does not collapse at any size from 1 to 100")
    func linearNoEvenSizeCollapse() throws {
        for size in UInt64(1) ... 100 {
            let effectiveRange = Gen.scaledRange(
                Int.min ... Int.max,
                scaling: .linear,
                size: size
            )
            let lower = effectiveRange.lowerBound
            let upper = effectiveRange.upperBound
            #expect(
                lower < upper,
                "At size \(size) the linear effective range collapsed to [\(lower), \(upper)]"
            )
        }
    }

    @Test("Exponential effective range does not collapse at any size from 1 to 100")
    func exponentialNoEvenSizeCollapse() throws {
        for size in UInt64(1) ... 100 {
            let effectiveRange = Gen.scaledRange(
                Int.min ... Int.max,
                scaling: .exponential,
                size: size
            )
            let lower = effectiveRange.lowerBound
            let upper = effectiveRange.upperBound
            #expect(
                lower < upper,
                "At size \(size) the exponential effective range collapsed to [\(lower), \(upper)]"
            )
        }
    }

    @Test("Linear effective range grows monotonically on signed types")
    func linearEffectiveRangeGrowsMonotonically() throws {
        var previousWidth: UInt64 = 0
        for size in stride(from: UInt64(5), through: 100, by: 5) {
            let effectiveRange = Gen.scaledRange(
                Int.min ... Int.max,
                scaling: .linear,
                size: size
            )
            let lowerBits = effectiveRange.lowerBound.bitPattern64
            let upperBits = effectiveRange.upperBound.bitPattern64
            let width = upperBits - lowerBits
            #expect(
                width >= previousWidth,
                "Width at size \(size) (\(width)) is smaller than previous (\(previousWidth))"
            )
            previousWidth = width
        }
    }
}

// MARK: - Helpers

private func sample<Value>(
    _ gen: ReflectiveGenerator<Value>,
    count: Int,
    seed: UInt64
) -> [Value] {
    var iter = ValueInterpreter(gen, seed: seed, maxRuns: UInt64(count))
    var values: [Value] = []
    values.reserveCapacity(count)
    while let value = try? iter.next() {
        values.append(value)
    }
    return values
}

private func medianMagnitude(_ samples: [Int]) -> Double {
    let magnitudes = samples.map { abs(Double($0)) }.sorted()
    guard magnitudes.isEmpty == false else { return 0 }
    return magnitudes[magnitudes.count / 2]
}

private func signCounts(_ samples: [Int]) -> (negatives: Int, positives: Int) {
    var negatives = 0
    var positives = 0
    for value in samples {
        if value < 0 { negatives += 1 }
        if value > 0 { positives += 1 }
    }
    return (negatives, positives)
}

private func signCountsDouble(_ samples: [Double]) -> (negatives: Int, positives: Int) {
    var negatives = 0
    var positives = 0
    for value in samples {
        if value < 0 { negatives += 1 }
        if value > 0 { positives += 1 }
    }
    return (negatives, positives)
}
