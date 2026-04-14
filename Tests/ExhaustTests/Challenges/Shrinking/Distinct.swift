//
//  Distinct.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation
import Testing
@testable import Exhaust

@Suite("Shrinking Challenge: Distinct")
struct DistinctShrinkingChallenge {
    /**
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/distinct.md
     This tests the example provided for the property "a list of integers containing at least three distinct elements".

     This is interesting because:

     1. Most property-based testing libraries will not successfully normalize (i.e. always return the same answer) this property, because it requires reordering examples to do so.
     2. Hypothesis and test.check both provide a built in generator for "a list of distinct elements", so the "example of size at least N" provides a sort of lower bound for how well they can shrink those built in generators.

     The expected smallest falsified sample is [0, 1, -1] or [0, 1, 2].
     */
    @Test("Distinct, Full")
    func distinct() {
        let gen = #gen(.int().array(length: 3 ... 30))
        var report: ExhaustReport?
        let counterExample = #exhaust(
            gen,
            .suppress(.issueReporting),

            .replay(5_023_515_172_476_973_421),
            .onReport { report = $0 }
        ) {
            Set($0).count < 3
        }
        if let report { print("[PROFILE] Distinct: \(report.profilingSummary)") }
        #expect(counterExample == [-1, 0, 1])
    }

    @Test("Distinct, reflected counterexample")
    func distinctReflected() {
        let gen = #gen(.int().array(length: 3 ... 30))
        let value = [1337, 80085, 69, 67]
        var report: ExhaustReport?
        let counterExample = #exhaust(
            gen,
            .suppress(.issueReporting),

            .reflecting(value),
            .onReport { report = $0 }
        ) {
            Set($0).count < 3
        }
        if let report { print("[PROFILE] DistinctReflected: \(report.profilingSummary)") }
        #expect(counterExample == [-1, 0, 1])
    }
}
