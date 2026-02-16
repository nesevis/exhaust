//
//  BinaryHeap.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

@testable import Exhaust
import Foundation
import Testing

@Suite("Shrinking Challenge: Binary Heap")
struct BinaryHeapShrinkingChallenge {
    /*
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/binheap.md
     This is based on an example from QuickCheck's test suite (via the SmartCheck paper). It generates binary heaps, and then uses a wrong implementation of a function that converts the binary heap to a sorted list and asserts that the result is sorted.

     Interestingly most libraries seem to never find the smallest example here, which is the four valued heap
        (0, None, (0, (0, None, None), (1, None, None)))
     This is essentially because small examples are "too sparse", so it's very hard to find one by luck.
     */
    @Test("Binary heap, Full", .disabled("Not implemented"))
    func binaryHeapFull() {
        // …etc
    }
}
