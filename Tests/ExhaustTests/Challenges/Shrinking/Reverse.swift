//
//  Reverse.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import ExhaustCore
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
    func reverseFull() throws {
        let gen = #gen(.uint()).array(length: 1 ... 1000)
        
        let output = #exhaust(gen, .useKleisliReducer, .suppressIssueReporting) { arr in
            arr.elementsEqual(arr.reversed())
        }
        
        #expect(output == [0, 1])
    }
}
