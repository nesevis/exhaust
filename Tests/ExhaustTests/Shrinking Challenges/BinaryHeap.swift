//
//  BinaryHeap.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation
import Testing
@testable import Exhaust

@MainActor
@Suite("Shrinking Challenge: Binary Heap")
struct BinaryHeapShrinkingChallenge {
    /*
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/binheap.md
     This is based on an example from QuickCheck's test suite (via the SmartCheck paper). It generates binary heaps, and then uses a wrong implementation of a function that converts the binary heap to a sorted list and asserts that the result is sorted.

     Interestingly most libraries seem to never find the smallest example here, which is the four valued heap
        (0, None, (0, (0, None, None), (1, None, None)))
     This is essentially because small examples are "too sparse", so it's very hard to find one by luck.
     */

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
    /// satisfy the invariant by construction. Reflection is lost but the
    /// `ValueAndChoiceTreeInterpreter` provides the ChoiceTree directly.
    static func heapGen(min: Int = 0, depth: UInt64) -> ReflectiveGenerator<Heap<Int>> {
        let maxVal = 100
        let emptyGen: ReflectiveGenerator<Heap<Int>> = Gen.just(.empty)

        guard depth > 0, min <= maxVal else {
            return emptyGen
        }

        let nodeGen = Gen.choose(in: min ... maxVal)
            .bind { value in
                Gen.zip(
                    heapGen(min: value, depth: depth / 2),
                    heapGen(min: value, depth: depth / 2),
                )
                .mapped(
                    forward: { left, right in Heap.node(value, left, right) },
                    backward: { heap in
                        switch heap {
                        case let .node(_, left, right): (left, right)
                        case .empty: (.empty, .empty)
                        }
                    },
                )
            }

        return Gen.pick(choices: [
            (1, emptyGen),
            (7, nodeGen),
        ])
    }

    static let gen = heapGen(depth: 6)

    /// The property: if the heap satisfies the invariant, then `toSortedList`
    /// must produce a sorted list containing the same elements as `toList`.
    static let property: (Heap<Int>) -> Bool = { heap in
        guard invariant(heap) else { return true }
        let xs = toSortedList(heap)
        let sorted = toList(heap).sorted()
        return sorted == xs.sorted() && xs == xs.sorted()
    }

    // MARK: - Tests

    @Test("Binary heap, Full")
    func binaryHeapFull() throws {
        let iterator = ValueAndChoiceTreeInterpreter(Self.gen, materializePicks: true, seed: 1337, maxRuns: 100)
        let (value, tree) = try #require(iterator.first(where: { Self.property($0.0) == false }))
        #expect(Self.property(value) == false)

        let (_, output) = try #require(try Interpreters.reduce(gen: Self.gen, tree: tree, config: .fast, property: Self.property))
        #expect(Self.property(output) == false)

        // The shrunken result should have 4 values — the minimal failing heap
        let outputValues = Self.toList(output)
        #expect(output == Heap<Int>.node(0, .empty, .node(0, .node(1, .empty, .empty), .node(0, .empty, .empty))))
        #expect(outputValues == [0, 0, 1, 0])
    }
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
