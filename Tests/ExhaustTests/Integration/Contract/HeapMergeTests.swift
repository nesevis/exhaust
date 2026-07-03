// MARK: - Heap Merge Contract Test

//
// Inspired by Hypothesis's rule-based stateful testing tutorial
// (David MacIver, "Rule Based Stateful Testing", 2016-04-19).
//
// The original demonstrates multi-object stateful workflows using bundles:
// multiple heap instances are created, pushed to, popped from, and merged.
// This port reframes the problem as a `@Contract` test where commands select
// among previously created heaps by resolving a generated index against
// spec-owned handle state (wrap-around indexing, skip when empty).
//
// The SUT is a `BuggyHeap` (a min-heap backed by an array) with a deliberate
// merge bug: when merging another heap with more than one element, the last
// element is silently dropped. This requires creating at least two heaps,
// pushing two or more values into the source, and then merging — a sequence
// that exercises bundle creation, drawing, and consumption.

import Exhaust
import ExhaustTestSupport
import Testing

// MARK: - Tests

@Suite("Heap merge contract tests", .serialized, .tags(.contract))
struct HeapMergeTests {
    @Test("Detects dropped element during merge via invariant or postcondition")
    func detectsDroppedElementDuringMergeViaInvariantOrPostcondition() async throws {
        // Bonsai uses 464 invocations in 71ms
        // Legacy uses 256 in 23ms
        // Bonsai does not reduce as well (6 vs 5)
        let result = try #require(
            await #execute(
                HeapMergeContract.self,
                .commandLimit(12),
                .budget(.extensive),
                .suppress(.issueReporting),
                .replay(2_244_429_497_963_284_422)
            )
        )

        #expect(result.trace.contains { step in
            switch step.outcome {
                case .invariantFailed, .checkFailed: true
                default: false
            }
        })
    }
}

@Suite("Heap aliasing contract tests (self-merge)", .serialized, .tags(.contract))
struct HeapAliasingTests {
    @Test("Sorted-splice merge violates heap property after repeated self-merges")
    func sortedSpliceMergeViolatesHeapPropertyAfterRepeatedSelfMerges() async throws {
        // Legacy: 90 invocations, 31ms, CE 5 steps
        // Bonsai: 151 invocations, 26ms, CE 5 steps
        let result = try #require(
            await #execute(
                HeapAliasingContract.self,
                .commandLimit(20),
                .suppress(.issueReporting),
                .replay(6_161_601_321_680_111_336)
            )
        )

        // TODO: Make expectation stronger:

        /*
         Counterexample:
           [
             [0]: .newHeap,
             [1]: .push(
               heapIndex: 0,
               value: 0
             ),
             [2]: .push(
               heapIndex: 0,
               value: 1
             ),
             [3]: .push(
               heapIndex: 0,
               value: 0
             ),
             [4]: .merge(
               index1: 0,
               index2: 0
             )
           ]
         */

        #expect(result.trace.contains { step in
            switch step.outcome {
                case .invariantFailed, .checkFailed: true
                default: false
            }
        })
    }
}

// MARK: - Contract

// Uses parallel arrays (`heaps` and `expectedContents`) indexed by integer
// handles stored in the spec-owned `liveHeaps` list. Each command resolves a
// generated index against `liveHeaps` with wrap-around to select which heap
// to operate on. The `merge` command removes the source handle (destroying
// it) and keeps the target handle, mirroring the Hypothesis tutorial's use
// of bundle consumption for exclusive ownership.

@Contract(.sequential)
final class HeapMergeContract {
    var expectedContents: [[Int]] = []
    @SystemUnderTest var heaps: [BuggyHeap] = []
    var liveHeaps: [Int] = []

    @Invariant
    func elementCountsMatch() -> Bool {
        heaps.indices.allSatisfy { heaps[$0].count == expectedContents[$0].count }
    }

    @Command(weight: 3)
    func newHeap() throws {
        heaps.append(BuggyHeap())
        expectedContents.append([])
        liveHeaps.append(heaps.count - 1)
    }

    @Command(weight: 5, .int(in: 0 ... 99), .int(in: 0 ... 50))
    func push(heapIndex: Int, value: Int) throws {
        guard liveHeaps.isEmpty == false else { throw skip() }
        let idx = liveHeaps[heapIndex % liveHeaps.count]
        heaps[idx].push(value)
        expectedContents[idx].append(value)
        expectedContents[idx].sort()
    }

    @Command(weight: 3, .int(in: 0 ... 99))
    func pop(heapIndex: Int) throws {
        guard liveHeaps.isEmpty == false else { throw skip() }
        let idx = liveHeaps[heapIndex % liveHeaps.count]
        guard !heaps[idx].isEmpty else { throw skip() }
        let actual = heaps[idx].pop()
        let expectedMin = expectedContents[idx].removeFirst()
        try check(actual == expectedMin, "pop must return the minimum element")
    }

    @Command(weight: 2, .int(in: 0 ... 99), .int(in: 0 ... 99))
    func merge(sourceIndex: Int, targetIndex: Int) throws {
        guard liveHeaps.count >= 2 else { throw skip() }
        let src = liveHeaps.remove(at: sourceIndex % liveHeaps.count)
        let tgt = liveHeaps[targetIndex % liveHeaps.count]
        heaps[tgt].merge(heaps[src])
        expectedContents[tgt] = (expectedContents[tgt] + expectedContents[src]).sorted()
    }

    func failureDescription() -> String? {
        "\(heaps)"
    }
}

// Faithfully reproduces the MacIver article's multi-heap scenario. Both
// merge arguments resolve by index without removal, allowing self-merge —
// `merge(v1, v1)` selects the same heap object for both parameters.
// Because `SpliceHeap` is a class, push/pop mutations are visible through
// all references to that heap.
//
// No separate model is needed. The invariant checks the heap property
// structurally (parent ≤ children at every index), and the pop
// postcondition verifies that the returned value is the minimum.

@Contract(.sequential)
final class HeapAliasingContract {
    @SystemUnderTest var allHeaps: [SpliceHeap] = []

    @Invariant
    func heapPropertyHolds() -> Bool {
        allHeaps.allSatisfy { heap in
            heap.elements.indices.allSatisfy { i in
                let left = 2 * i + 1
                let right = 2 * i + 2
                let leftOk = left >= heap.count || heap.elements[i] <= heap.elements[left]
                let rightOk = right >= heap.count || heap.elements[i] <= heap.elements[right]
                return leftOk && rightOk
            }
        }
    }

    @Command(weight: 2)
    func newHeap() throws {
        allHeaps.append(SpliceHeap())
    }

    @Command(weight: 4, .int(in: 0 ... 99), .int(in: -5 ... 5))
    func push(heapIndex: Int, value: Int) throws {
        guard allHeaps.isEmpty == false else { throw skip() }
        allHeaps[heapIndex % allHeaps.count].push(value)
    }

    @Command(weight: 2, .int(in: 0 ... 99))
    func pop(heapIndex: Int) throws {
        guard allHeaps.isEmpty == false else { throw skip() }
        let heap = allHeaps[heapIndex % allHeaps.count]
        guard !heap.isEmpty else { throw skip() }
        let expectedMin = heap.elements.min()!
        let actual = heap.pop()
        try check(actual == expectedMin, "pop must return the minimum element")
    }

    @Command(weight: 4, .int(in: 0 ... 99), .int(in: 0 ... 99))
    func merge(index1: Int, index2: Int) throws {
        guard allHeaps.isEmpty == false else { throw skip() }
        let heap1 = allHeaps[index1 % allHeaps.count]
        let heap2 = allHeaps[index2 % allHeaps.count]
        allHeaps.append(heap1.merged(with: heap2))
    }

    func failureDescription() -> String? {
        "\(allHeaps)"
    }
}

// MARK: - Types

// A min-heap backed by an array with standard sift-up/sift-down operations.
// All operations are correct except `merge`, which drops the last element
// from the source heap when it has more than one element.

struct BuggyHeap {
    private(set) var elements: [Int] = []

    mutating func push(_ value: Int) {
        elements.append(value)
        siftUp(elements.count - 1)
    }

    mutating func pop() -> Int? {
        guard !elements.isEmpty else { return nil }
        if elements.count == 1 { return elements.removeLast() }
        let min = elements[0]
        elements[0] = elements.removeLast()
        siftDown(0)
        return min
    }

    mutating func merge(_ other: BuggyHeap) {
        // Bug: drops the last element when the other heap has > 1 element.
        let source = other.elements
        if source.count > 1 {
            for element in source.dropLast() {
                push(element)
            }
        } else {
            for element in source {
                push(element)
            }
        }
    }

    var isEmpty: Bool {
        elements.isEmpty
    }

    var count: Int {
        elements.count
    }

    // MARK: - Heap internals

    private mutating func siftUp(_ index: Int) {
        var i = index
        while i > 0 {
            let parent = (i - 1) / 2
            guard elements[i] < elements[parent] else { break }
            elements.swapAt(i, parent)
            i = parent
        }
    }

    private mutating func siftDown(_ index: Int) {
        var i = index
        let count = elements.count
        while true {
            var smallest = i
            let left = 2 * i + 1
            let right = 2 * i + 2
            if left < count, elements[left] < elements[smallest] {
                smallest = left
            }
            if right < count, elements[right] < elements[smallest] {
                smallest = right
            }
            guard smallest != i else { break }
            elements.swapAt(i, smallest)
            i = smallest
        }
    }
}

// A reference-type min-heap for testing aliased handle references. Push and
// pop use correct sift-up/sift-down. The merge function uses a sorted-splice
// that treats heap arrays as sorted lists — a subtly wrong assumption since
// heaps are only partially ordered (parent ≤ children, but siblings are
// unordered). This is the "interestingly broken" merge from MacIver's article.
//
// Because SpliceHeap is a class, the handle list stores references. Resolving
// the same index twice yields the same object, enabling self-merge patterns
// like `merge(heap1=v1, heap2=v1)` that are central to the original
// Hypothesis counterexample. Push and pop mutate in place, so all references
// to the same heap see the latest state.

final class SpliceHeap {
    private(set) var elements: [Int] = []

    func push(_ value: Int) {
        elements.append(value)
        siftUp(elements.count - 1)
    }

    func pop() -> Int? {
        guard !elements.isEmpty else { return nil }
        if elements.count == 1 { return elements.removeLast() }
        let min = elements[0]
        elements[0] = elements.removeLast()
        siftDown(0)
        return min
    }

    // Bug: sorted-splice merge. This interleaves two heap arrays as if they
    // were sorted lists, but heap arrays are only partially ordered. The
    // result satisfies the heap property for small inputs but breaks after
    // enough merges create deep trees with misordered internal nodes.
    func merged(with other: SpliceHeap) -> SpliceHeap {
        let result = SpliceHeap()
        var i = 0, j = 0
        let x = elements, y = other.elements
        while i < x.count, j < y.count {
            if x[i] <= y[j] {
                result.elements.append(x[i])
                i += 1
            } else {
                result.elements.append(y[j])
                j += 1
            }
        }
        if i < x.count { result.elements.append(contentsOf: x[i...]) }
        if j < y.count { result.elements.append(contentsOf: y[j...]) }
        return result
    }

    var isEmpty: Bool {
        elements.isEmpty
    }

    var count: Int {
        elements.count
    }

    // MARK: - Heap internals

    private func siftUp(_ index: Int) {
        var i = index
        while i > 0 {
            let parent = (i - 1) / 2
            guard elements[i] < elements[parent] else { break }
            elements.swapAt(i, parent)
            i = parent
        }
    }

    private func siftDown(_ index: Int) {
        var i = index
        let count = elements.count
        while true {
            var smallest = i
            let left = 2 * i + 1
            let right = 2 * i + 2
            if left < count, elements[left] < elements[smallest] {
                smallest = left
            }
            if right < count, elements[right] < elements[smallest] {
                smallest = right
            }
            guard smallest != i else { break }
            elements.swapAt(i, smallest)
            i = smallest
        }
    }
}
