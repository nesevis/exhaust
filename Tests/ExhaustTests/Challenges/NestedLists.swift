//
//  NestedLists.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

@testable import Exhaust
import Foundation
import Testing

@Suite("Nested Lists Shrinking Challenge")
struct NestedListsShrinkingChallenge {
    /*
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/nestedlists.md
     This tests the performance of shrinking a list of lists, testing the false property that the sum of lengths of the element lists is at most 10.

     The reason this is interesting is that it has lots of local minima under pure deletion based approaches. e.g. [[0], ..., [0]] and [[0, ..., 0]] are both minima for this under anything that can only make individual elements smaller.

     Some libraries, e.g. Hypothesis and jqwik, can shrink this reliably to a single list of 11 elements: [[0, 0, 0, 0, 0, 0, 0, 0, 0, 0]].
     */
    @Test("Nested Lists, Full", .disabled("Not implemented"))
    func nestedListsFull() {
        // …etc
    }
}
