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

    // MARK: - Tests

    @Test("Binary heap, Full")
    func binaryHeapFull() throws {
        // The property: if the heap satisfies the invariant, then `toSortedList`
        // must produce a sorted list containing the same elements as `toList`.
        let property: @Sendable (Heap<Int>) -> Bool = { heap in
//            print("Attempt: \(heap)")
            guard Self.invariant(heap) else { return true }
            let xs = Self.toSortedList(heap)
            let sorted = Self.toList(heap).sorted()
            return sorted == xs.sorted() && xs == xs.sorted()
        }
        let boundGen = #gen(.uint64(in: 0 ... 20)).bind { Self.binaryHeapGen(depth: $0) }
        var report: ExhaustReport?
        let output = try #require(
            #exhaust(
                boundGen,
                .suppress(.issueReporting),
                .replay(1591),
                .logging(.debug),
                .onReport { report = $0 },
                property: property
            )
        )
        let rep = try #require(report)
        #expect(rep.propertyInvocations == 356)
        #expect(rep.totalMaterializations == 287)
        
        print(rep.profilingSummary)

        let outputValues = Self.toList(output)
        // The shrunken result should have 4 values — the minimal failing heap.
        // 1 *should* be the last value, as this is the shortlex smallest, but
        #expect(outputValues.sorted() == [0, 0, 0, 1])
    }

    // MARK: - Heap type

    indirect enum Heap<Element: Comparable>: Equatable {
        case empty
        case node(Element, Heap, Heap)
    }

    // MARK: - Heap operations

    /// Flattens a heap into a list via breadth-first traversal.
    static func toList<Element>(_ heap: Heap<Element>) -> [Element] {
        var queue = [heap]
        var result: [Element] = []
        while !queue.isEmpty {
            let current = queue.removeFirst()
            switch current {
            case .empty:
                continue
            case let .node(x, h1, h2):
                result.append(x)
                queue.append(h1)
                queue.append(h2)
            }
        }
        return result
    }

    /// Buggy conversion to sorted list — uses `toList` instead of recursing.
    /// This is the function under test; its bug is that it only correctly
    /// extracts the minimum, then flattens the rest without sorting.
    static func toSortedList<Element: Comparable>(_ heap: Heap<Element>) -> [Element] {
        switch heap {
        case .empty:
            []
        case let .node(x, h1, h2):
            [x] + toList(merge(h1, h2))
        }
    }

    /// Merges two heaps maintaining the min-heap invariant.
    static func merge<Element: Comparable>(_ h1: Heap<Element>, _ h2: Heap<Element>) -> Heap<Element> {
        switch (h1, h2) {
        case (_, .empty):
            h1
        case (.empty, _):
            h2
        case let (.node(x, h11, h12), .node(y, h21, h22)):
            if x <= y {
                .node(x, merge(h12, h2), h11)
            } else {
                .node(y, merge(h22, h1), h21)
            }
        }
    }

    /// Checks the min-heap invariant: parent <= both children, recursively.
    static func invariant(_ heap: Heap<some Comparable>) -> Bool {
        switch heap {
        case .empty:
            true
        case let .node(x, h1, h2):
            lte(x, h1) && lte(x, h2) && invariant(h1) && invariant(h2)
        }
    }

    private static func lte<Element: Comparable>(_ x: Element, _ heap: Heap<Element>) -> Bool {
        switch heap {
        case .empty:
            true
        case let .node(y, _, _):
            x <= y
        }
    }

    // MARK: - Generator

    /// Generates valid min-heaps by threading a minimum value through `bind`.
    /// Uses `bind` to constrain child values >= parent, so all generated heaps
    /// satisfy the invariant by construction.
    static func binaryHeapGen(min: Int = 0, depth: UInt64) -> ReflectiveGenerator<Heap<Int>> {
        let maxVal = Int.max
        let emptyGen: ReflectiveGenerator<Heap<Int>> = #gen(.just(.empty))

        guard depth > 0, min <= maxVal else {
            return emptyGen
        }

        let nodeGen = #gen(.int(in: min ... maxVal))
            .bind { value in
                #gen(
                    binaryHeapGen(min: value, depth: depth / 2),
                    binaryHeapGen(min: value, depth: depth / 2)
                )
                .mapped(
                    forward: { left, right in Heap.node(value, left, right) },
                    backward: { heap in
                        switch heap {
                        case let .node(_, left, right): (left, right)
                        case .empty: (.empty, .empty)
                        }
                    }
                )
            }

        return #gen(.oneOf(weighted: (1, emptyGen), (5, nodeGen)))
    }

    static let gen = binaryHeapGen(depth: 20)
}

extension BinaryHeapShrinkingChallenge.Heap: CustomDebugStringConvertible {
    var debugDescription: String {
        switch self {
        case .empty:
            "None"
        case let .node(value, left, right):
            "(\(value), \(left.debugDescription), \(right.debugDescription))"
        }
    }
}
