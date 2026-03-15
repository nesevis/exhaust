//
//  SemanticSimplestIntegrationTests.swift
//  ExhaustCoreTests
//
//  ChoiceValue.semanticSimplest tests that verify behavior across generated values.
//

import ExhaustCore
import Testing

@Suite("ChoiceValue.semanticSimplest Integration")
struct SemanticSimplestIntegrationTests {
    @Test("Unsigned semanticSimplest is always .unsigned(0, ...)")
    func unsignedSimplest() throws {
        let gen = Gen.choose(in: UInt64(0) ... UInt64(100_000))
        var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 200)
        while let rawValue = try iterator.next() {
            #expect(ChoiceValue.unsigned(rawValue, .uint64).semanticSimplest == .unsigned(0, .uint64))
        }
    }

    @Test("Signed semanticSimplest always has value 0")
    func signedSimplest() throws {
        let gen = Gen.choose(in: Int64(-50000) ... Int64(50000))
        var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 200)
        while let rawValue = try iterator.next() {
            let simplest = ChoiceValue(rawValue, tag: .int64).semanticSimplest
            guard case let .signed(int64Val, _, _) = simplest else {
                Issue.record("Expected .signed case")
                continue
            }
            #expect(int64Val == 0)
        }
    }

    @Test("Float semanticSimplest is always 0.0")
    func floatSimplest() throws {
        let gen = Gen.choose(in: -1000.0 ... 1000.0)
        var iterator = ValueInterpreter(gen, seed: 42, maxRuns: 200)
        while let rawValue = try iterator.next() {
            let simplest = ChoiceValue(rawValue, tag: .double).semanticSimplest
            guard case let .floating(doubleVal, _, _) = simplest else {
                Issue.record("Expected .floating case")
                continue
            }
            #expect(doubleVal == 0.0)
        }
    }
}
