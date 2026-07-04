//
//  Reverse.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Exhaust
import ExhaustTestSupport
import Foundation
import Testing

@Suite("Shrinking Challenge: Reverse", .tags(.challenge))
struct ReverseShrinkingChallenge {
    /// https://github.com/jlink/shrinking-challenge/blob/main/challenges/reverse.md
    /// This tests the (wrong) property that reversing a list of integers results in the same list. It is a basic example to validate that a library can reliably normalize simple sample data.
    @Test("Reverse, Full")
    func reverseFull() {
        let gen = #gen(.uint()).array(length: 1 ... 1000)
        let output = #exhaust(
            gen,
            .suppress(.issueReporting),
            .collectOpenPBTStats,
            .replay(33_556_013_978_236_435),
            .log(.debug)
        ) { arr in
            return arr.elementsEqual(arr.reversed())
        }

        #expect(output == [0, 1])
    }
}
