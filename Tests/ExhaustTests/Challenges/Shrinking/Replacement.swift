//
//  Replacement.swift
//  Exhaust
//
//  Created by Chris Kolbu on 21/3/2026.
//

import Foundation
import Testing
@testable import Exhaust

@Suite("Shrinking Challenge: Replacement")
struct ReplacementShrinkingChallenge {
    /*
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/replacement.md
     Based on the SmartCheck paper. Given a starting integer n in [0, 10^6] and a list
     of multipliers in [2, 5], compute the running product sequence. The (wrong) property
     asserts that no product reaches 10^6.

     The property fails whenever the cumulative product reaches 1_000_000. The smallest
     counterexample is (1_000_000, []) — n itself is already >= 10^6.
     */

    @Test("Replacement, Full")
    func replacementFull() throws {
        let gen = #gen(.int(in: 0 ... 1_000_000), .int(in: 2 ... 5).array())

        let output = try #require(
            #exhaust(
                gen,
                .suppressIssueReporting
            ) { initial, multipliers in
                Self.prods(initial, multipliers).allSatisfy { $0 < 1_000_000 }
            }
        )

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
