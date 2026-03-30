//
//  NestedLists.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation
import Testing
@testable import Exhaust

@Suite("Shrinking Challenge: Nested Lists")
struct NestedListsShrinkingChallenge {
    /**
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/nestedlists.md
     This tests the performance of shrinking a list of lists, testing the false property that the sum of lengths of the element lists is at most 10.

     The reason this is interesting is that it has lots of local minima under pure deletion based approaches. e.g. [[0], ..., [0]] and [[0, ..., 0]] are both minima for this under anything that can only make individual elements smaller.

     Some libraries, e.g. Hypothesis and jqwik, can shrink this reliably to a single list of 11 elements: [[0, 0, 0, 0, 0, 0, 0, 0, 0, 0]].
     */
    @Test("Nested Lists")
    func nestedListsFull() {
        ExhaustLog.setConfiguration(.init(isEnabled: true, minimumLevel: .info, categoryMinimumLevels: [.reducer: .debug], format: .human))
        let gen = #gen(.uint().array().array())
        print()
        var report: ExhaustReport?
        let output = #exhaust(
            gen,
            .suppressIssueReporting,
            .onReport { report = $0 }
//            .replay(13580297670505979531)
        ) { arrs in
            var count = 0
            for arr in arrs {
                count += arr.count
            }
            return count <= 10
        }
        if let report { print("[PROFILE] NestedLists: \(report.profilingSummary)") }

        #expect(output == [Array(repeating: UInt(0), count: 11)])
    }
}
