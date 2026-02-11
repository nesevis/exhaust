//
//  Deletion.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

@testable import Exhaust
import Foundation
import Testing

@Suite("Deletion Shrinking Challenge")
struct DeletionShrinkingChallenge {
    /*
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/deletion.md
     This tests the property "if we remove an element from a list, the element is no longer in the list".
     The remove function we use however only actually removes the first instance of the element, so this fails whenever the list contains a duplicate and we try to remove one of those elements.

     This example is interesting for a couple of reasons:

     It's a nice easy to explain example of property-based testing.
     
     Shrinking duplicates simultaneously is something that most property-based testing libraries can't do.
     
     The expected smallest falsified sample is ([0, 0], 0).
     */
    @Test("Deletion, Full", .disabled("Not implemented"))
    func deletionFull() {
        // …etc
    }
}
