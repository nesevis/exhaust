import Exhaust
import Testing

// MARK: - Tests

@Suite("Invariant-only contract tests")
struct InvariantOnlyTests {
    @Test("Circular buffer capacity invariant detects overflow")
    func circularBufferOverflow() throws {
        let result = try #require(
            #exhaust(
                CircularBufferContract.self,
                commandLimit: 6,
                .suppress(.issueReporting)
            )
        )

        #expect(result.trace.contains { step in
            if case .invariantFailed = step.outcome { return true }
            return false
        })
    }

    @Test("Sorted backing invariant detects unsorted insert")
    func sortedBackingViolation() throws {
        let result = try #require(
            #exhaust(
                SortedBackingContract.self,
                commandLimit: 5,
                .suppress(.issueReporting)
            )
        )

        #expect(result.trace.contains { step in
            if case .invariantFailed = step.outcome { return true }
            return false
        })
    }
}

// MARK: - Contract: Circular buffer capacity

/// No `@Model` — the invariant checks a structural property of the SUT alone.
/// The bug surfaces when `write` is called on a full buffer because there's
/// no capacity guard in the SUT implementation.
@Contract
struct CircularBufferContract {
    @SUT var buffer = CircularBuffer(capacity: 2)

    @Invariant
    func countWithinCapacity() -> Bool {
        buffer.count >= 0 && buffer.count <= buffer.capacity // swiftlint:disable:this empty_count
    }

    @Command(weight: 3)
    mutating func write() throws {
        buffer.write(0)
    }

    @Command(weight: 2)
    mutating func read() throws {
        guard !buffer.isEmpty else { throw skip() }
        _ = buffer.read()
    }

    @Command(weight: 1)
    mutating func clear() throws {
        buffer.clear()
    }
}

// MARK: - Contract: Priority queue sorted backing

@Contract
struct SortedBackingContract {
    @SUT var queue = BuggyPriorityQueue()

    @Invariant
    func backingIsSorted() -> Bool {
        zip(queue.elements, queue.elements.dropFirst()).allSatisfy { $0 <= $1 }
    }

    @Command(weight: 3, #gen(.int(in: 0 ... 20)))
    mutating func enqueue(value: Int) throws {
        queue.enqueue(value)
    }

    @Command(weight: 2)
    mutating func dequeue() throws {
        guard !queue.isEmpty else { throw skip() }
        _ = queue.dequeue()
    }
}

// MARK: - Types

/// A circular buffer that should never hold more elements than its capacity.
/// The bug: `write` doesn't check capacity, so writing to a full buffer
/// increments `count` past the limit.
struct CircularBuffer {
    private var storage: [Int]
    private var head = 0
    private var tail = 0
    private(set) var count = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        storage = Array(repeating: 0, count: capacity)
    }

    mutating func write(_ value: Int) {
        // Bug: no capacity check — overwrites and increments count unconditionally
        storage[tail % capacity] = value
        tail = (tail + 1) % capacity
        count += 1
    }

    mutating func read() -> Int? {
        guard count > 0 else { return nil } // swiftlint:disable:this empty_count
        let value = storage[head]
        head = (head + 1) % capacity
        count -= 1
        return value
    }

    var isEmpty: Bool {
        count <= 0 // swiftlint:disable:this empty_count
    }

    var isFull: Bool {
        count >= capacity
    }

    mutating func clear() {
        head = 0
        tail = 0
        count = 0
    }
}

/// A priority queue backed by an unsorted array (the bug). Dequeue should
/// return the minimum element, and the backing storage should always
/// represent a valid state. With an unsorted backing store, the invariant
/// "elements are sorted" won't hold.
struct BuggyPriorityQueue {
    private(set) var elements: [Int] = []

    mutating func enqueue(_ value: Int) {
        // Bug: appends without maintaining sorted order.
        // A correct implementation would insert at the right position.
        elements.append(value)
    }

    var isEmpty: Bool {
        elements.isEmpty
    }

    mutating func dequeue() -> Int? {
        guard !elements.isEmpty else { return nil }
        // Finds and removes the minimum — correct behavior, but the
        // invariant checks sorted order of the backing store.
        if let minIndex = elements.indices.min(by: { elements[$0] < elements[$1] }) {
            return elements.remove(at: minIndex)
        }
        return nil
    }
}
