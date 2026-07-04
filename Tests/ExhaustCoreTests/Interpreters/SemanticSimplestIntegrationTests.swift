//
//  SemanticSimplestIntegrationTests.swift
//  ExhaustCoreTests
//
//  `semanticSimplest` does not depend on the stored value, only on the tag, so
//  edge-case inputs per tag cover it without drawing generated values.
//

import ExhaustCore
import Testing

@Suite("ChoiceValue.semanticSimplest")
struct SemanticSimplestIntegrationTests {
    @Test("Unsigned semanticSimplest is always .unsigned(0, ...)", arguments: [UInt64(0), 1, 42, 100_000, UInt64.max])
    func unsignedSimplest(rawValue: UInt64) {
        #expect(ChoiceValue(rawValue, tag: .uint64).semanticSimplest == ChoiceValue(UInt64(0), tag: .uint64))
    }

    @Test("Signed semanticSimplest always has value 0", arguments: [Int64(0), 1, -1, 50000, -50000, Int64.max, Int64.min])
    func signedSimplest(rawValue: Int64) {
        let simplest = ChoiceValue(rawValue, tag: .int64).semanticSimplest
        #expect(simplest.decodedSignedValue == 0)
    }

    @Test("Float semanticSimplest is always 0.0", arguments: [0.0, -0.0, 1.0, -1000.0, 1000.0, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude])
    func floatSimplest(rawValue: Double) {
        let simplest = ChoiceValue(rawValue, tag: .double).semanticSimplest
        #expect(simplest.decodedDoubleValue == 0.0)
    }
}
