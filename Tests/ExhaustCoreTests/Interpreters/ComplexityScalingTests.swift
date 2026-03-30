import ExhaustCore
import Testing

/// Verifies that size-scaled generators produce values whose magnitude grows with iteration count.
///
/// The ``ValueInterpreter`` increments its internal size parameter from 0 on each call to `next()`. Generators that use ``SizeScaling`` (the default for all numeric types without an explicit range) should produce small values early and progressively larger values as the size grows.
@Suite("Complexity Scaling")
struct ComplexityScalingTests {
    // MARK: - Signed Integers

    @Test("Int64 magnitude grows over 100 iterations")
    func int64MagnitudeGrows() throws {
        let gen = Gen.choose(in: Int64.min ... Int64.max, scaling: Int64.defaultScaling)
        let values = try generateSigned(gen, count: 100)
        assertMagnitudeGrows(values, name: "Int64")
    }

    @Test("Int32 magnitude grows over 100 iterations")
    func int32MagnitudeGrows() throws {
        let gen = Gen.choose(in: Int32.min ... Int32.max, scaling: Int32.defaultScaling)
        let values = try generateSigned(gen, count: 100)
        assertMagnitudeGrows(values, name: "Int32")
    }

    @Test("Int16 magnitude grows over 100 iterations")
    func int16MagnitudeGrows() throws {
        let gen = Gen.choose(in: Int16.min ... Int16.max, scaling: Int16.defaultScaling)
        let values = try generateSigned(gen, count: 100)
        assertMagnitudeGrows(values, name: "Int16")
    }

    @Test("Int8 magnitude grows over 100 iterations")
    func int8MagnitudeGrows() throws {
        let gen = Gen.choose(in: Int8.min ... Int8.max, scaling: Int8.defaultScaling)
        let values = try generateSigned(gen, count: 100)
        // Int8 domain is only 256 values — 100x growth is impossible.
        assertMagnitudeGrows(values, factor: 3, name: "Int8")
    }

    // MARK: - Unsigned Integers

    @Test("UInt64 magnitude grows over 100 iterations")
    func uint64MagnitudeGrows() throws {
        let gen = Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling)
        let values = try generateUnsigned(gen, count: 100)
        assertMagnitudeGrows(values, name: "UInt64")
    }

    @Test("UInt32 magnitude grows over 100 iterations")
    func uint32MagnitudeGrows() throws {
        let gen = Gen.choose(in: UInt32.min ... UInt32.max, scaling: UInt32.defaultScaling)
        let values = try generateUnsigned(gen, count: 100)
        assertMagnitudeGrows(values, name: "UInt32")
    }

    // MARK: - Explicit Range with Scaling

    @Test("Explicit range with linear scaling still ramps up")
    func explicitRangeWithScaling() throws {
        let gen = Gen.choose(in: Int64(0) ... 1_000_000, scaling: .linear)
        let values = try generateSigned(gen, count: 100)
        // Linear scaling over a narrow range: first quarter averages ~12.5% of max,
        // last quarter averages ~87.5%. Ratio is roughly 7x, not 100x.
        assertMagnitudeGrows(values, factor: 3, name: "Int64 0...1M linear")
    }

    // MARK: - Constant Scaling (Control)

    @Test("Constant scaling uses full range from the start")
    func constantScalingUsesFullRange() throws {
        let gen = Gen.choose(in: Int64.min ... Int64.max, scaling: .constant)
        let values = try generateSigned(gen, count: 50)

        let earlyMagnitude = averageMagnitude(Array(values.prefix(10)))
        let lateMagnitude = averageMagnitude(Array(values.suffix(10)))

        // Constant scaling means no ramp-up. Early should be at least 10% of late
        // (both should be roughly half of Int64.max with uniform random sampling).
        #expect(
            earlyMagnitude > lateMagnitude / 10,
            "Constant scaling: early magnitude \(earlyMagnitude) should be comparable to late \(lateMagnitude)"
        )
    }

    // MARK: - Arrays

    @Test("Array length grows with size scaling")
    func arrayLengthGrows() throws {
        let gen = Gen.arrayOf(
            Gen.choose(in: UInt8.min ... UInt8.max, scaling: .constant),
            within: 0 ... 50,
            scaling: .linear
        )
        var iter = ValueInterpreter(gen, seed: 42, maxRuns: 100)
        var lengths: [Int] = []
        for _ in 0 ..< 100 {
            let array = try iter.next()!
            lengths.append(array.count)
        }

        let earlyAverage = Double(lengths.prefix(10).reduce(0, +)) / 10.0
        let lateAverage = Double(lengths.suffix(10).reduce(0, +)) / 10.0

        #expect(
            lateAverage > earlyAverage * 2,
            "Array lengths should grow: early avg \(earlyAverage), late avg \(lateAverage)"
        )
    }
}

// MARK: - Helpers

private func generateSigned<Value: SignedInteger & BitPatternConvertible>(
    _ gen: ReflectiveGenerator<Value>,
    count: Int,
    seed: UInt64 = 0
) throws -> [Double] {
    var iter = ValueInterpreter(gen, seed: seed, maxRuns: UInt64(count))
    var magnitudes: [Double] = []
    for _ in 0 ..< count {
        let value = try iter.next()!
        magnitudes.append(abs(Double(value)))
    }
    return magnitudes
}

private func generateUnsigned<Value: UnsignedInteger & BitPatternConvertible>(
    _ gen: ReflectiveGenerator<Value>,
    count: Int,
    seed: UInt64 = 0
) throws -> [Double] {
    var iter = ValueInterpreter(gen, seed: seed, maxRuns: UInt64(count))
    var magnitudes: [Double] = []
    for _ in 0 ..< count {
        let value = try iter.next()!
        magnitudes.append(Double(value))
    }
    return magnitudes
}

private func averageMagnitude(_ values: [Double]) -> Double {
    guard values.isEmpty == false else { return 0 }
    return values.reduce(0, +) / Double(values.count)
}

/// Asserts that the average magnitude of the last quarter of values is significantly
/// larger than the average magnitude of the first quarter.
///
/// - Parameter factor: The minimum ratio between late and early magnitude. Defaults to 100, which is appropriate for wide types (32-bit and above). Narrow types (Int8) and narrow explicit ranges need a smaller factor.
private func assertMagnitudeGrows(
    _ magnitudes: [Double],
    factor: Double = 100,
    name: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let quarterCount = magnitudes.count / 4
    guard quarterCount >= 5 else { return }

    let earlyMagnitude = averageMagnitude(Array(magnitudes.prefix(quarterCount)))
    let lateMagnitude = averageMagnitude(Array(magnitudes.suffix(quarterCount)))

    #expect(
        lateMagnitude > earlyMagnitude * factor,
        "\(name): late magnitude (\(lateMagnitude)) should be >\(factor)x early magnitude (\(earlyMagnitude))",
        sourceLocation: sourceLocation
    )
}
