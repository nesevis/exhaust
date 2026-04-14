//
//  ReducerReduceValuesIntegrationTests.swift
//  ExhaustTests
//
//  Reducer test that requires #exhaust macro (Exhaust module).
//

import Testing
@testable import Exhaust

@Suite("Reducer Pass 5 Integration")
struct ReducerReduceValuesIntegrationTests {
    @Test("Non-reflectable generator shrinks correctly")
    func nonReflectableGeneratorShrinksCorrectly() {
        let stringGen = #gen(.character(in: "0" ... "9"))
            .array(length: 0 ... 20)
            // Reversible, but only accidentally ([Character] is more or less equal to String)
            .map { String($0) }

        let gen = #gen(stringGen, stringGen, stringGen) {
            // Concatenating; irreversible
            $0 + $1 + $2
        }

        let counterExample = #exhaust(gen, .suppress(.issueReporting)) { str in
            str.contains("5") == false
        }

        #expect(counterExample == "5")
    }
}
