//
//  Replacement.swift
//  Exhaust
//
//  Created by Chris Kolbu on 21/3/2026.
//

import Foundation
import Testing
@testable import Exhaust

@Suite("Experimental Challenge: Replacement")
struct ReplacementChallenge {
    /*
     From the MacIver & Donaldson ECOOP 2020 artifact (hypothesis-ecoop-2020-artifact,
     smartcheck-benchmarks/evaluations/replacement). Originally a Haskell QuickCheck
     benchmark with multipliers in [2, 5]; the Hypothesis reimplementation widened
     multipliers to [2, 10].

     Given a starting integer n in [0, 10^6] and a list of multipliers in [2, 5],
     compute the running product sequence. The (wrong) property asserts that no
     product reaches 10^6.

     The property fails whenever the cumulative product reaches 1_000_000. The smallest
     counterexample is (1_000_000, []) — n itself is already >= 10^6.

     This challenge exhibits multiplicative local minima: the reducer converges to
     different factorizations of 1_000_000 (for example (200000, [5]) or (8000, [5,5,5]))
     depending on the starting counterexample's array length. Reaching the global
     minimum requires increasing the initial value while deleting multipliers — a
     direction the reducer cannot take.
     */

    @Test("Replacement, Full")
    func replacementFull() throws {
        let gen = #gen(.int(in: 0 ... 1_000_000), .int(in: 2 ... 10).array())

        var report: ExhaustReport?
        let output = try #require(
            #exhaust(
                gen,
                .suppressIssueReporting,
                .onReport { report = $0 }
            ) { initial, multipliers in
                Self.prods(initial, multipliers).allSatisfy { $0 < 1_000_000 }
            }
        )

        if let report { print("[PROFILE] Replacement: \(report.profilingSummary)") }
        #expect(Self.prods(output.0, output.1).contains { $0 >= 1_000_000 })
    }

    // MARK: - Helpers

    /// Builds the running product sequence: `[n, n*x0, n*x0*x1, ...]`.
    static func prods(_ initial: Int, _ multipliers: [Int]) -> [Int] {
        var result = [initial]
        var running = initial
        for multiplier in multipliers {
            running *= multiplier
            result.append(running)
        }
        return result
    }
}
