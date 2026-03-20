import Foundation
import Testing
@testable import Exhaust

@Suite("Experimental Challenge: fast-check Dichotomy")
struct FastCheckDichotomyChallenge {
    /*
     Ported from fast-check's regression test for barely-infinite shrinking
     (fixed in fast-check v2.12.0). The original bug: the integer shrinker
     used a simple boolean context ("have I shrunk before?"), causing it to
     restart from zero at each nesting level — O(n²) steps to converge on
     large ranges.

     The property encodes a two-dimensional threshold with a gap constraint:
     both a and b must be >= 1000, b >= a, and the difference b - a must be
     >= 10 and < 1000. This creates a diagonal failure region that requires
     coordinated shrinking of two independent coordinates.

     Expected smallest counterexample: (1000, 1010)
     - a = 1000: the smallest value satisfying a >= 1000
     - b = 1010: the smallest value satisfying b >= a and 10 <= b - a < 1000

     The challenge tests both shrink quality (reaching the exact minimum) and
     shrink efficiency (converging without quadratic probe counts). A shrinker
     that restarts binary search from scratch at each level would take O(n²)
     probes; Bonsai's stall cache (when implemented) should make cycle 2+ a
     zero-cost confirmation pass.
     
     This is akin to the Difference tests from the shrinking challenge
     */

    @Test("fast-check dichotomy regression")
    func fastCheckDichotomy() {
        let gen = #gen(.int(in: 0 ... 1_000_000)).array(length: 2)

        let property: @Sendable ([Int]) -> Bool = { pair in
            let a = pair[0]
            let b = pair[1]
            if a < 1000 { return true }
            if b < 1000 { return true }
            if b < a { return true }
            if abs(a - b) < 10 { return true }
            return b - a >= 1000
        }

        let counterExample = [1000, 1010]
        #expect(property(counterExample) == false)

        let output = #exhaust(
            gen,
            .suppressIssueReporting,
            .reflecting([500_000, 500_500]),
            property: property
        )

        #expect(output == counterExample)
    }
}
