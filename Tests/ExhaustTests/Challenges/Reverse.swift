//
//  Reverse.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

@testable import Exhaust
import Foundation
import Testing

@Suite("Reverse Shrinking Challenge")
struct ReverseShrinkingChallenge {
    /*
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/reverse.md
     This tests the (wrong) property that reversing a list of integers results in the same list. It is a basic example to validate that a library can reliably normalize simple sample data.
     */
    @Test("Reverse, Full", .disabled("Not implemented"))
    func reverseFull() {
        let arrGen = Gen.arrayOf(Int.arbitrary, within: 1...10)
        
        // …etc
    }
}
