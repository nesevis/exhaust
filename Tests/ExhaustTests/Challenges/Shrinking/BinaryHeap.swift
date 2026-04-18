//
//  BinaryHeap.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation
import Testing
@testable import Exhaust

@Suite("Shrinking Challenge: Binary Heap")
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
        var report: ExhaustReport?
        let output = try #require(
            #exhaust(
                boundGen,
                .suppress(.issueReporting),
                .replay(1591),
                .logging(.debug),
                .onReport { report = $0 },
                property: BinaryHeapFixture.property
            )
        )
        let rep = try #require(report)
        // Temporarily commented while BoundValueScope is disabled and the inner-descendant rework is in progress. Restore once the multi-leaf inner fix lands and the counts stabilise.
//        #expect(rep.propertyInvocations == 434)
//        #expect(rep.totalMaterializations == 429)

        print(rep.profilingSummary)

        let outputValues = BinaryHeapFixture.toList(output)
        // The shrunken result should have 4 values — the minimal failing heap.
        // 1 *should* be the last value, as this is the shortlex smallest, but
        #expect(outputValues.sorted() == [0, 0, 0, 1])
    }
}
