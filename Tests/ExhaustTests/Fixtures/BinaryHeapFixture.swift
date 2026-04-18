//
//  BinaryHeapFixture.swift
//  ExhaustTests
//
//  Shared fixture for the ECOOP shrinking challenge "BinaryHeap":
//  https://github.com/jlink/shrinking-challenge/blob/main/challenges/binheap.md
//

@testable import Exhaust

/// Min-heap of `Int` plus a buggy `toSortedList` that violates the property `toSortedList(h).sorted() == toList(h).sorted()`.
enum BinaryHeapFixture {
    indirect enum Heap<Element: Comparable>: Equatable {
        case empty
        case node(Element, Heap, Heap)
    }

    /// Flattens a heap into a list via breadth-first traversal.
    static func toList<Element>(_ heap: Heap<Element>) -> [Element] {
        var queue = [heap]
        var result: [Element] = []
        while queue.isEmpty == false {
            let current = queue.removeFirst()
            switch current {
            case .empty:
                continue
            case let .node(value, left, right):
                result.append(value)
                queue.append(left)
                queue.append(right)
            }
        }
        return result
    }

    /// Buggy conversion to sorted list — uses `toList` instead of recursing. The bug is that it only correctly extracts the minimum, then flattens the rest without sorting.
    static func toSortedList<Element: Comparable>(_ heap: Heap<Element>) -> [Element] {
        switch heap {
        case .empty:
            []
        case let .node(value, left, right):
            [value] + toList(merge(left, right))
        }
    }

    /// Merges two heaps maintaining the min-heap invariant.
    static func merge<Element: Comparable>(_ left: Heap<Element>, _ right: Heap<Element>) -> Heap<Element> {
        switch (left, right) {
        case (_, .empty):
            left
        case (.empty, _):
            right
        case let (.node(leftValue, leftLeft, leftRight), .node(rightValue, rightLeft, rightRight)):
            if leftValue <= rightValue {
                .node(leftValue, merge(leftRight, right), leftLeft)
            } else {
                .node(rightValue, merge(rightRight, left), rightLeft)
            }
        }
    }

    /// Checks the min-heap invariant: parent <= both children, recursively.
    static func invariant(_ heap: Heap<some Comparable>) -> Bool {
        switch heap {
        case .empty:
            true
        case let .node(value, left, right):
            lte(value, left) && lte(value, right) && invariant(left) && invariant(right)
        }
    }

    private static func lte<Element: Comparable>(_ value: Element, _ heap: Heap<Element>) -> Bool {
        switch heap {
        case .empty:
            true
        case let .node(other, _, _):
            value <= other
        }
    }

    /// Generates valid min-heaps by threading a minimum value through `bind`. Uses `bind` to constrain child values >= parent, so all generated heaps satisfy the invariant by construction.
    static func heapGen(min: Int = 0, depth: UInt64) -> ReflectiveGenerator<Heap<Int>> {
        let maxValue = Int.max
        let emptyGen: ReflectiveGenerator<Heap<Int>> = #gen(.just(.empty))

        guard depth > 0, min <= maxValue else {
            return emptyGen
        }

        let nodeGen = #gen(.int(in: min ... maxValue))
            .bind { value in
                #gen(
                    heapGen(min: value, depth: depth / 2),
                    heapGen(min: value, depth: depth / 2)
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

    /// Top-level generator with depth 20 — matches the ECOOP harness configuration.
    static let gen = heapGen(depth: 20)

    /// Property under test: if the heap satisfies the min-heap invariant, then ``toSortedList(_:)`` produces a sorted list with the same elements as ``toList(_:)``. False because of the buggy ``toSortedList(_:)``.
    @Sendable
    static func property(_ heap: Heap<Int>) -> Bool {
        guard invariant(heap) else { return true }
        let sortedFromHeap = toSortedList(heap)
        let sortedFromList = toList(heap).sorted()
        return sortedFromList == sortedFromHeap.sorted() && sortedFromHeap == sortedFromHeap.sorted()
    }
}

extension BinaryHeapFixture.Heap: CustomDebugStringConvertible {
    var debugDescription: String {
        switch self {
        case .empty:
            "None"
        case let .node(value, left, right):
            "(\(value), \(left.debugDescription), \(right.debugDescription))"
        }
    }
}
