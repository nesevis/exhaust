//
//  SemanticSimplestIntegrationTests.swift
//  ExhaustTests
//
//  ChoiceValue.semanticSimplest tests that require #exhaust macro (Exhaust module).
//

import Testing
@testable import Exhaust
import ExhaustCore

@Suite("ChoiceValue.semanticSimplest Integration")
struct SemanticSimplestIntegrationTests {
    @Test("Unsigned semanticSimplest is always .unsigned(0, ...)")
    func unsignedSimplest() {
        #exhaust(#gen(.uint64(in: 0 ... 100_000))) { rawValue in
            ChoiceValue.unsigned(rawValue, .uint64).semanticSimplest == .unsigned(0, .uint64)
        }
    }

    @Test("Signed semanticSimplest always has value 0")
    func signedSimplest() {
        #exhaust(#gen(.int64(in: -50000 ... 50000))) { rawValue in
            let simplest = ChoiceValue(rawValue, tag: .int64).semanticSimplest
            guard case let .signed(int64Val, _, _) = simplest else { return false }
            return int64Val == 0
        }
    }

    @Test("Float semanticSimplest is always 0.0")
    func floatSimplest() {
        #exhaust(#gen(.double(in: -1000.0 ... 1000.0))) { rawValue in
            let simplest = ChoiceValue(rawValue, tag: .double).semanticSimplest
            guard case let .floating(doubleVal, _, _) = simplest else { return false }
            return doubleVal == 0.0
        }
    }
}
