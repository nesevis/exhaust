import Exhaust

// MARK: - Type

indirect enum Heap<Element: Comparable>: Equatable {
    case empty
    case node(Element, Heap, Heap)
}

extension Heap: CustomDebugStringConvertible {
    var debugDescription: String {
        switch self {
        case .empty:
            "None"
        case let .node(value, left, right):
            "(\(value), \(left.debugDescription), \(right.debugDescription))"
        }
    }
}

// MARK: - Generator

func binaryHeapGen(min: Int = 0, depth: UInt64) -> ReflectiveGenerator<Heap<Int>> {
    let maxVal = 100
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

// MARK: - Buggy Heap Operations

func heapToList<Element>(_ heap: Heap<Element>) -> [Element] {
    var queue = [heap]
    var result: [Element] = []
    while queue.isEmpty == false {
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

func heapToSortedList<Element: Comparable>(_ heap: Heap<Element>) -> [Element] {
    switch heap {
    case .empty:
        []
    case let .node(x, h1, h2):
        [x] + heapToList(heapMerge(h1, h2))
    }
}

private func heapMerge<Element: Comparable>(_ h1: Heap<Element>, _ h2: Heap<Element>) -> Heap<Element> {
    switch (h1, h2) {
    case (_, .empty):
        h1
    case (.empty, _):
        h2
    case let (.node(x, h11, h12), .node(y, h21, h22)):
        if x <= y {
            .node(x, heapMerge(h12, h2), h11)
        } else {
            .node(y, heapMerge(h22, h1), h21)
        }
    }
}

func heapInvariant(_ heap: Heap<some Comparable>) -> Bool {
    switch heap {
    case .empty:
        true
    case let .node(x, h1, h2):
        heapLte(x, h1) && heapLte(x, h2) && heapInvariant(h1) && heapInvariant(h2)
    }
}

private func heapLte<Element: Comparable>(_ x: Element, _ heap: Heap<Element>) -> Bool {
    switch heap {
    case .empty:
        true
    case let .node(y, _, _):
        x <= y
    }
}

// MARK: - Property

let binaryHeapProperty: @Sendable (Heap<Int>) -> Bool = { heap in
    guard heapInvariant(heap) else { return true }
    let sorted = heapToSortedList(heap)
    let reference = heapToList(heap).sorted()
    return reference == sorted.sorted() && sorted == sorted.sorted()
}
