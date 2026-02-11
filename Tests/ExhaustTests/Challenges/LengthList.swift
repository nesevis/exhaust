//
//  LengthList.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

@testable import Exhaust
import Foundation
import Testing

@Suite("Length List Shrinking Challenge")
struct LengthListShrinkingChallenge {
    /*
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/lengthlist.md
     A list should be generated first by picking a length between 1 and 100, then by generating a list of precisely that length whose elements are integers between 0 and 1000. The test should fail if the maximum value of the list is 900 or larger.

     This list should specifically be generated using monadic combinators (bind) or some equivalent, and this is a test that is only interesting for integrated shrinking. This is only interesting as a test of a problem some property-based testing libraries have with monadic bind**. In particular the use of the length parameter is critical, and the challenge is to shrink this example to [900] reliably when using a PBT library's built in generator for lists.
     ** https://clojure.github.io/test.check/growth-and-shrinking.html#unnecessary-bind
     */
    @Test("Length List, Full", .disabled("Not implemented"))
    func lengthListFull() {
        let gen = Gen.arrayOf(Gen.choose(in: UInt(0)...1000), within: 1...100)
        
        // …etc
    }
}
