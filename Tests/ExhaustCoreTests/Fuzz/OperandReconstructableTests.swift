//
//  OperandReconstructableTests.swift
//  ExhaustTests
//

import ExhaustCore
import Testing

@Suite("Operand Reconstruction")
struct OperandReconstructableTests {
    @Test("Int decodes a natural two's-complement operand")
    func intDecodesNaturalValue() {
        let value = 0x3FFF_1234_5678_9ABC
        #expect(Int.reconstruct(fromOperand: UInt64(value)) == value)
    }

    @Test("Int decodes a negative operand through the standard bit pattern, not the choice-space encoding")
    func intDecodesNegativeNaturally() {
        let value = -42
        #expect(Int.reconstruct(fromOperand: UInt64(bitPattern: Int64(value))) == value)
    }

    @Test("UInt32 decodes the low four bytes")
    func uint32DecodesLowBytes() {
        #expect(UInt32.reconstruct(fromOperand: 0xDEAD_BEEF) == 0xDEAD_BEEF)
    }

    @Test("Double decodes an IEEE bit pattern")
    func doubleDecodesIEEE() {
        let value = 3.14159
        #expect(Double.reconstruct(fromOperand: value.bitPattern) == value)
    }

    @Test("String decodes a printable small-string word")
    func stringDecodesPrintableWord() {
        #expect(String.reconstruct(fromOperand: word(from: Array("Banana07".utf8))) == "Banana07")
    }

    @Test("String rejects a small-string flag word")
    func stringRejectsFlagWord() {
        // A small-string second word: content bytes zero, count/flags in the high byte.
        #expect(String.reconstruct(fromOperand: 0xE800_0000_0000_0000) == nil)
    }

    @Test("Derivation finds a conformance and rejects a non-conforming type")
    func derivationDispatchesOnConformance() {
        let intReconstructor = OperandReconstruction.reconstructor(for: Int.self)
        #expect(intReconstructor != nil)
        #expect(intReconstructor?(99) == 99)

        let personReconstructor = OperandReconstruction.reconstructor(for: Person.self)
        #expect(personReconstructor == nil)
    }

    @Test("Erased derivation keys on a runtime metatype and rejects a non-conforming type")
    func erasedDerivationDispatchesOnRuntimeType() {
        let intReconstructor = OperandReconstruction.erasedReconstructor(for: Int.self)
        #expect(intReconstructor != nil)
        #expect(intReconstructor?(99) as? Int == 99)

        let personReconstructor = OperandReconstruction.erasedReconstructor(for: Person.self)
        #expect(personReconstructor == nil)
    }

    // MARK: - Helpers

    private struct Person {
        let age: Int
    }

    private func word(from bytes: [UInt8]) -> UInt64 {
        bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * $1.offset) }
    }
}
