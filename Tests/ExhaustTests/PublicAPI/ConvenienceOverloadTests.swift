import Exhaust
import Foundation
import Testing

@Suite("Convenience overloads for Int/Double literal ranges")
struct ConvenienceOverloadTests {
    // MARK: - ClosedRange<Double> overloads

    @Test("float16(in:) accepts Double range literal")
    func float16DoubleRange() throws {
        let value = try #example(.float16(in: 0.0 ... 1.0))
        #expect(value >= 0.0 && value <= 1.0)
    }

    // MARK: - ClosedRange<Int> overloads

    @Test("string(from:length:) accepts Int range literal")
    func stringFromCharacterSetIntRange() throws {
        let value = try #example(.string(from: .alphanumerics, length: 1 ... 10))
        #expect(value.count >= 1 && value.count <= 10)
    }

    // MARK: - Int overloads for UInt64 parameters

    @Test("array(_:length:) static accepts Int literal")
    func staticArrayIntLength() throws {
        let value = try #example(.array(.bool(), length: 3))
        #expect(value.count == 3)
    }

    @Test("array(length:) instance accepts Int literal")
    func instanceArrayIntLength() throws {
        let value = try #example(.bool().array(length: 3))
        #expect(value.count == 3)
    }

    @Test("set(_:count:) static accepts Int literal")
    func staticSetIntCount() throws {
        let value = try #example(.set(.int(in: 0 ... 1000), count: 3))
        #expect(value.count == 3)
    }

    @Test("set(count:) instance accepts Int literal")
    func instanceSetIntCount() throws {
        let value = try #example(.int(in: 0 ... 1000).set(count: 3))
        #expect(value.count == 3)
    }

    @Test("data(length:) accepts Int literal")
    func dataIntLength() throws {
        let value = try #example(.data(length: 16))
        #expect(value.count == 16)
    }

    @Test("resize() accepts Int literal")
    func resizeIntValue() throws {
        let value = try #example(.int(in: 0 ... 1000).resize(50))
        #expect(value >= 0 && value <= 1000)
    }

    // MARK: - data(prefix:) overloads

    @Test("data(prefix:) produces data starting with prefix")
    func dataWithPrefix() throws {
        let magic: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBE]
        let value = try #example(.data(prefix: magic))
        #expect(Array(value.prefix(magic.count)) == magic)
    }

    @Test("data(prefix:length:) accepts Int range literal")
    func dataWithPrefixIntRange() throws {
        let magic: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let value = try #example(.data(prefix: magic, length: 16 ... 64))
        let suffixLength = value.count - magic.count
        #expect(suffixLength >= 16 && suffixLength <= 64)
        #expect(Array(value.prefix(magic.count)) == magic)
    }

    @Test("data(prefix:length:) accepts Int literal")
    func dataWithPrefixIntLength() throws {
        let magic: [UInt8] = [0xFE, 0xED, 0xFA, 0xCE]
        let value = try #example(.data(prefix: magic, length: 32))
        #expect(value.count == magic.count + 32)
        #expect(Array(value.prefix(magic.count)) == magic)
    }
}
