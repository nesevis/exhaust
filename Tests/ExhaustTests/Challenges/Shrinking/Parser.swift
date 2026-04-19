//
//  Parser.swift
//  Exhaust
//
//  Created by Chris Kolbu on 21/3/2026.
//

import Foundation
import Testing
@testable import Exhaust

@Suite("Shrinking Challenge: Parser")
struct ParserShrinkingChallenge {
    /*
     https://github.com/mc-imperial/hypothesis-ecoop-2020-artifact/tree/master/smartcheck-benchmarks/evaluations/parser
     Based on the SmartCheck paper. A simple language AST is serialized to a string
     and then parsed back. The parser has two bugs:
       1. `And` is parsed with swapped operands.
       2. `Or` is parsed as `And` with swapped operands.
     The property `parse(serialize(lang)) == lang` fails for any AST containing
     `And` with non-equal operands (bug 1 swaps them) or any `Or` expression
     (bug 2 changes Or to And).

     The expected minimal counterexample is the simplest Lang wrapping an Or
     expression: `Lang([], [Func(a, [Or(Int(0), Int(0))], [])])`.
     Even equal operands trigger bug 2 since it changes the constructor.
     */

    @Test("Parser, Full")
    func parserFull() throws {
        var report: ExhaustReport?
        let output = try #require(
            #exhaust(
                ParserFixture.langGen,
                .randomOnly, // coverage takes a long time
                .budget(.exorbitant),
                .logging(.debug, .keyValue),
                .suppress(.issueReporting),
                .onReport { report = $0 },
                property: ParserFixture.property
            )
        )
        if let report { print("[PROFILE] Parser: \(report.profilingSummary)") }

        print("Output: \(output)")
        #expect(ParserFixture.property(output) == false)

        // Size metric matches the SmartCheck/Hypothesis evaluation.
        // Hypothesis achieves ~3.31, QuickCheck ~3.99, SmartCheck ~4.08.
        // Exhaust averages ~3.67
        let outputSize = ParserFixture.size(output)
        print("Size: \(outputSize)")
        #expect(outputSize < 4)
    }
}
