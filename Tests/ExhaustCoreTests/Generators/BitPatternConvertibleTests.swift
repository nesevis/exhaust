import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("BitPattern conversion")
struct BitPatternConvertibleTests {
    @Test("Every integer width preserves values and encoded words")
    func integerEncodings() throws {
        try integerEncoding(Int.self)
        try integerEncoding(Int8.self)
        try integerEncoding(Int16.self)
        try integerEncoding(Int32.self)
        try integerEncoding(Int64.self)
        try integerEncoding(UInt.self)
        try integerEncoding(UInt8.self)
        try integerEncoding(UInt16.self)
        try integerEncoding(UInt32.self)
        try integerEncoding(UInt64.self)
    }

    @Test("Floating encodings preserve every bit, including NaN payloads and signed zero")
    func floatingEncodings() throws {
        try exhaustCheck(Gen.choose() as Generator<UInt64>) { word in
            let value = Double(bitPattern: word)
            return Double(bitPattern64: value.bitPattern64).bitPattern == word
                && Double(bitPattern64: word).bitPattern64 == word
        }
        try exhaustCheck(Gen.choose() as Generator<UInt32>) { word in
            let value = Float(bitPattern: word)
            return Float(bitPattern64: value.bitPattern64).bitPattern == word
                && Float(bitPattern64: UInt64(word)).bitPattern64 == UInt64(word)
        }
        for value in [Double.zero, -Double.zero, .infinity, -.infinity, .nan] {
            #expect(Double(bitPattern64: value.bitPattern64).bitPattern == value.bitPattern)
        }
        for value in [Float.zero, -Float.zero, .infinity, -.infinity, .nan] {
            #expect(Float(bitPattern64: value.bitPattern64).bitPattern == value.bitPattern)
        }
    }

    @Test("Property test Float bit pattern representation is sequential with size")
    func propertyTestFloatBitPatternSequentiality() throws {
        let gen = Gen.zip(
            Gen.choose(in: -Float.greatestFiniteMagnitude ... Float(0)),
            Gen.choose(in: Float(1) ... Float.greatestFiniteMagnitude.nextDown)
        )
        try exhaustCheck(gen) { low, high in
            low.bitPattern64 < high.bitPattern64
        }
    }

    @Test("Property test Double bit pattern representation is sequential with size")
    func propertyTestDoubleBitPatternSequentiality() throws {
        let gen = Gen.zip(
            Gen.choose(in: -Double.greatestFiniteMagnitude ... 0),
            Gen.choose(in: 1.0 ... Double.greatestFiniteMagnitude.nextDown)
        )
        try exhaustCheck(gen) { low, high in
            low.bitPattern64 < high.bitPattern64
        }
    }

    @Test("Property test Int64 bit pattern representation is sequential with size")
    func propertyTestSignedIntegerBitPatternSequentiality() throws {
        let gen = Gen.zip(
            Gen.choose(in: Int64.min ... Int64(0)),
            Gen.choose(in: Int64(1) ... Int64.max)
        )
        try exhaustCheck(gen) { low, high in
            low.bitPattern64 < high.bitPattern64
        }
    }

    @Test("Double range 0.0 ... -0.0 generates zeros without trapping")
    func mixedSignZeroDoubleRange() throws {
        var iterator = ValueInterpreter(Gen.choose(in: 0.0 ... -0.0 as ClosedRange<Double>), seed: 1, maxRuns: 10)
        var generated = 0
        while let value = try iterator.next() {
            #expect(value == 0.0)
            generated += 1
        }
        #expect(generated == 10)
    }

    @Test("Float range 0.0 ... -0.0 generates zeros without trapping")
    func mixedSignZeroFloatRange() throws {
        var iterator = ValueInterpreter(Gen.choose(in: Float(0.0) ... Float(-0.0)), seed: 1, maxRuns: 10)
        var generated = 0
        while let value = try iterator.next() {
            #expect(value == 0.0)
            generated += 1
        }
        #expect(generated == 10)
    }

    @Test("Double range -0.0 ... 0.0 is unaffected by the bound reorder")
    func orderedZeroDoubleRange() throws {
        var iterator = ValueInterpreter(Gen.choose(in: -0.0 ... 0.0 as ClosedRange<Double>), seed: 1, maxRuns: 10)
        var generated = 0
        while let value = try iterator.next() {
            #expect(value == 0.0)
            generated += 1
        }
        #expect(generated == 10)
    }
}

// MARK: - Shared integer contract

private func integerEncoding<Value: FixedWidthInteger & BitPatternConvertible>(_ type: Value.Type) throws {
    // Independent endpoint pins complement the two inverse laws.
    #expect(Value.min.bitPattern64 == 0, "\(type)")
    #expect(Value.max.bitPattern64 == Value.bitPatternRange.upperBound, "\(type)")
    for value in [Value.min, .max, 0, 1] {
        #expect(Value(bitPattern64: value.bitPattern64) == value, "\(type)")
    }
    try exhaustCheck(Gen.choose() as Generator<Value>) { value in
        Value(bitPattern64: value.bitPattern64) == value
    }
    try exhaustCheck(Gen.choose(in: Value.bitPatternRange)) { word in
        Value(bitPattern64: word).bitPattern64 == word
    }
}
