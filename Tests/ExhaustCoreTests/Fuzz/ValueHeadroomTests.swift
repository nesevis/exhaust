import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Value headroom")
struct ValueHeadroomTests {
    @Test("The two unsigned directions sum to the explicit range's width")
    func unsignedHeadroomSumsToTheRangeWidth() throws {
        let triples = Gen.zip(
            Gen.choose(in: UInt64(0) ... 1000),
            Gen.choose(in: UInt64(0) ... 1000),
            Gen.choose(in: UInt64(0) ... 1000)
        ).map { first, second, third -> (UInt64, UInt64, UInt64) in
            let sorted = [first, second, third].sorted()
            return (sorted[0], sorted[1], sorted[2])
        }
        try exhaustCheck(triples, maxIterations: 300) { lower, current, upper in
            let value = ChoiceSequenceValue.Value(
                choice: ChoiceValue(UInt(current).bitPattern64, tag: .uint),
                validRange: UInt(lower).bitPattern64 ... UInt(upper).bitPattern64,
                isRangeExplicit: true
            )
            let upward = value.headroom(upward: true, tag: .uint)
            let downward = value.headroom(upward: false, tag: .uint)
            return upward == upper - current
                && downward == current - lower
                && upward + downward == upper - lower
        }
    }

    @Test("Signed integer headroom respects the XOR encoding")
    func signedHeadroom() {
        let value = ChoiceSequenceValue.Value(
            choice: ChoiceValue(Int(3).bitPattern64, tag: .int),
            validRange: Int(-7).bitPattern64 ... Int(7).bitPattern64,
            isRangeExplicit: true
        )
        #expect(value.headroom(upward: true, tag: .int) == 4)
        #expect(value.headroom(upward: false, tag: .int) == 10)
    }

    @Test("Non-explicit range yields max headroom for the bit pattern")
    func nonExplicitRange() {
        let current = UInt(50).bitPattern64
        let value = ChoiceSequenceValue.Value(
            choice: ChoiceValue(current, tag: .uint),
            validRange: UInt(10).bitPattern64 ... UInt(90).bitPattern64,
            isRangeExplicit: false
        )
        #expect(value.headroom(upward: true, tag: .uint) == UInt64.max - current)
        #expect(value.headroom(upward: false, tag: .uint) == current)
    }

    @Test("Nil range yields max headroom for the bit pattern")
    func nilRange() {
        let current = UInt(50).bitPattern64
        let value = ChoiceSequenceValue.Value(
            choice: ChoiceValue(current, tag: .uint),
            validRange: nil,
            isRangeExplicit: false
        )
        #expect(value.headroom(upward: true, tag: .uint) == UInt64.max - current)
        #expect(value.headroom(upward: false, tag: .uint) == current)
    }

    @Test("Float16 without explicit range bounds headroom by finite magnitude")
    func float16NonExplicitRange() {
        let encoded = Float16Emulation.encodedBitPattern(from: 100.0)
        let value = ChoiceSequenceValue.Value(
            choice: ChoiceValue(encoded, tag: .float16),
            validRange: nil,
            isRangeExplicit: false
        )
        let upward = value.headroom(upward: true, tag: .float16)
        let downward = value.headroom(upward: false, tag: .float16)
        #expect(upward <= 65504)
        #expect(downward <= 65504 + 100)
        #expect(upward > 0)
        #expect(downward > 0)
    }

    @Test("Double without explicit range saturates to max because finite magnitude exceeds UInt64")
    func doubleNonExplicitRangeSaturates() {
        let value = ChoiceSequenceValue.Value(
            choice: ChoiceValue(Double(1000.0).bitPattern64, tag: .double),
            validRange: nil,
            isRangeExplicit: false
        )
        #expect(value.headroom(upward: true, tag: .double) == .max)
        #expect(value.headroom(upward: false, tag: .double) == .max)
    }

    @Test("Float16 near finite max has small upward headroom")
    func float16NearMax() {
        let encoded = Float16Emulation.encodedBitPattern(from: 65000.0)
        let value = ChoiceSequenceValue.Value(
            choice: ChoiceValue(encoded, tag: .float16),
            validRange: nil,
            isRangeExplicit: false
        )
        let upward = value.headroom(upward: true, tag: .float16)
        #expect(upward <= 512)
        #expect(upward > 0)
    }

    @Test("Float with explicit range computes headroom from bounds")
    func floatExplicitRange() {
        let lower = Float(-10.0).bitPattern64
        let upper = Float(10.0).bitPattern64
        let current = Float(3.0).bitPattern64
        let value = ChoiceSequenceValue.Value(
            choice: ChoiceValue(current, tag: .float),
            validRange: lower ... upper,
            isRangeExplicit: true
        )
        #expect(value.headroom(upward: true, tag: .float) == 7)
        #expect(value.headroom(upward: false, tag: .float) == 13)
    }
}
