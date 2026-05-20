//
//  BinaryHeap.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import ExhaustTestSupport
import Foundation
import Testing
@testable import Exhaust

@Suite("Shrinking Challenge: Binary Heap", .tags(.challenge))
struct BinaryHeapShrinkingChallenge {
    /*
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/binheap.md
     This is based on an example from QuickCheck's test suite (via the SmartCheck paper). It generates binary heaps, and then uses a wrong implementation of a function that converts the binary heap to a sorted list and asserts that the result is sorted.

     Interestingly most libraries seem to never find the smallest example here, which is the four valued heap
        (0, None, (0, (0, None, None), (1, None, None)))
     This is essentially because small examples are "too sparse", so it's very hard to find one by luck.
     */

    @Test("Binary heap, Full")
    func binaryHeapFull() throws {
        let boundGen = #gen(.uint64(in: 0 ... 20)).bind { BinaryHeapFixture.heapGen(depth: $0) }
        let output = try #require(
            #exhaust(
                boundGen,
                .suppress(.issueReporting),
                .budget(.extensive),
                .replay(2250),
                .logging(.debug),
                property: BinaryHeapFixture.property
            )
        )
        let outputValues = BinaryHeapFixture.toList(output)
        // The shrunken result should have 4 values — the minimal failing heap.
        // 1 *should* be the last value, as this is the shortlex smallest, but
        #expect(outputValues.sorted() == [0, 0, 0, 1])
    }

    @Test("Binary heap, Recursive combinator")
    func binaryHeapRecursive() throws {
        let recursiveGen = BinaryHeapFixture.heapGenRecursive()
        let output = try #require(
            #exhaust(
                recursiveGen,
                .suppress(.issueReporting),
                .replay(.numeric(10_358_026_062_479_193_394)),
                .logging(.debug),
                property: BinaryHeapFixture.property
            )
        )

        let outputValues = BinaryHeapFixture.toList(output)

        // This is a pathological seed that results in a basin [0, 0, 1, 2]
        withKnownIssue {
            #expect(outputValues.sorted() == [0, 0, 0, 1])
        }
    }
}
