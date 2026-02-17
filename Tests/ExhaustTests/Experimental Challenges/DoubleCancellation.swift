//
//  DoubleCancellation.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/2/2026.
//

@testable import Exhaust
import Foundation
import Testing

@Suite("Experimental Challenge: Double Cancellation")
struct DoubleCancellationChallenge {
    /*
     This tests the property `(a + b) - a == b` for two positive doubles.

     Due to floating-point precision, this fails when `a` is large enough
     that `b` is lost to rounding when added to `a`. Specifically, when
     `a >= 2^53` and `b = 1.0`, the double `a + 1.0` rounds back to `a`,
     so `(a + 1.0) - a = 0.0 != 1.0`.

     This is an anti-correlated shrinking challenge:
     - `a` must stay LARGE for the property to fail
     - `b` must shrink toward 1.0 (the range minimum)
     - `reduceValues` binary-searches `a` toward 1.0, which fixes the property
     - `redistributeNumericPairs` tries to equalize `a` and `b`, also wrong

     The reducer must discover that `a` has a lower bound (2^53) below which
     the property passes, while `b` can freely shrink. The binary search on
     `a`'s encoded bit pattern should find this boundary.

     Expected smallest counterexample: (9007199254740992.0, 1.0)
     where 9007199254740992.0 = 2^53, the exact threshold of cancellation.
     */

    @Test("Double cancellation", .disabled("Float shrinking isn't implemented correctly"))
    func doubleCancellation() throws {
        let gen = Gen.zip(
            Gen.choose(in: 1.0 ... 1e18),
            Gen.choose(in: 1.0 ... 1e18)
        )

        let property: (Double, Double) -> Bool = { a, b in
            (a + b) - a == b
        }

        let value = (1e16, 2.0)
        #expect(property(value.0, value.1) == false)

        let tree = try #require(try Interpreters.reflect(gen, with: value))
        let (_, output) = try #require(try Interpreters.reduce(
            gen: gen, tree: tree, config: .slow, property: property
        ))

        print("Shrunk to: (\(output.0), \(output.1))")
        print("2^53 = \(pow(2.0, 53))")

        // b should shrink to the range minimum
        #expect(output.1 == 1.0)
        // a should converge to the cancellation boundary: 2^53
        #expect(output.0 == 9_007_199_254_740_992.0)
    }
}
