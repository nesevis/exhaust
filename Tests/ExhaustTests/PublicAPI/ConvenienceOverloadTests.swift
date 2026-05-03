import Testing
@testable import Exhaust
import Foundation

@Suite("Convenience overloads for Int/Double literal ranges")
struct ConvenienceOverloadTests {

    // MARK: - ClosedRange<Double> overloads

    @Test("float16(in:) accepts Double range literal")
    func float16DoubleRange() {
        let value = #example(.float16(in: 0.0...1.0))
        #expect(value >= 0.0 && value <= 1.0)
    }

    // MARK: - ClosedRange<Int> overloads

    @Test("string(from:length:) accepts Int range literal")
    func stringFromCharacterSetIntRange() {
        let value = #example(.string(from: .alphanumerics, length: 1...10))
        #expect(value.count >= 1 && value.count <= 10)
    }

    // MARK: - Int overloads for UInt64 parameters

    @Test("array(_:length:) static accepts Int literal")
    func staticArrayIntLength() {
        let value = #example(.array(.bool(), length: 3))
        #expect(value.count == 3)
    }

    @Test("array(length:) instance accepts Int literal")
    func instanceArrayIntLength() {
        let value = #example(.bool().array(length: 3))
        #expect(value.count == 3)
    }

    @Test("set(_:count:) static accepts Int literal")
    func staticSetIntCount() {
        let value = #example(.set(.int(in: 0...1000), count: 3))
        #expect(value.count == 3)
    }

    @Test("set(count:) instance accepts Int literal")
    func instanceSetIntCount() {
        let value = #example(.int(in: 0...1000).set(count: 3))
        #expect(value.count == 3)
    }

    @Test("data(length:) accepts Int literal")
    func dataIntLength() {
        let value = #example(.data(length: 16))
        #expect(value.count == 16)
    }

    @Test("resize() accepts Int literal")
    func resizeIntValue() {
        let value = #example(.int(in: 0...1000).resize(50))
        #expect(value >= 0 && value <= 1000)
    }
}
