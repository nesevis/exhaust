//
//  Reverse.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation
import Testing
@testable import Exhaust

@Suite("Shrinking Challenge: Reverse")
struct ReverseShrinkingChallenge {
    /**
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/reverse.md
     This tests the (wrong) property that reversing a list of integers results in the same list. It is a basic example to validate that a library can reliably normalize simple sample data.
     */
    @Test("Reverse, Full")
    func reverseFull() {
        let gen = #gen(.uint()).array(length: 1 ... 1000)
        var report: ExhaustReport?
        let output = #exhaust(
            gen,
            .suppressIssueReporting,

            .replay(33_556_013_978_236_435),
            .logging(.debug, .keyValue),
            .onReport { report = $0 }
        ) { arr in
            print("Attempt: \(arr)")
            return arr.elementsEqual(arr.reversed())
        }
        if let report { print("[PROFILE] Reverse: \(report.profilingSummary)") }

        #expect(output == [0, 1])
    }
}
