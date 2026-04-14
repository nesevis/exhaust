// MARK: - Circular Queue Contract Test

//
// Inspired by gopter's `example_circularqueue_test.go` (Jan Ritter, gopter project).
//
// The original tests a ring buffer with a position-dependent corruption bug:
// when the internal write pointer reaches position 4, the stored value is
// silently incremented. This requires a specific interleaving of puts and gets
// to advance the write pointer to the right position, making it a good test
// for shrinking quality — the reducer must find a minimal command sequence
// that reaches the corrupted state and then observes it via a get.
//
// The existing `CircularBufferContract` in Exhaust only checks a capacity
// invariant (count within bounds). This test upgrades to full FIFO
// postcondition verification: every `get` must return the element that was
// `put` first, in order. The model is a simple FIFO array.

import Exhaust
import Testing

// MARK: - Tests

@Suite("Circular queue contract tests")
struct CircularQueueTests {
    // The model is a plain `[Int]` tracking FIFO order. Three commands exercise
    // the ring buffer:
    //
    //   - `put(value)` — appends to both model and SUT. Skips if at capacity.
    //   - `get()` — removes front element. Postcondition checks the returned
    //     value matches the model's front. Skips if empty.
    //   - `size()` — postcondition checks count agrees with model.
    //
    // An invariant ensures the SUT count stays within bounds.

    @Test("Position-dependent corruption detected via FIFO postcondition")
    func circularQueueCorruption() throws {
        let result = try #require(
            #exhaust(
                CircularQueueContract.self,
                commandLimit: 10,
                .budget(.expensive),
                .suppress(.issueReporting),
                .replay(12_892_450_489_757_532_783)
            )
        )

        #expect(result.trace.contains { step in
            if case .checkFailed = step.outcome { return true }
            return false
        })
    }
}

// MARK: - Contract

@Contract
struct CircularQueueContract {
    @Model var expected: [Int] = []
    @SUT var queue = BuggyCircularQueue(capacity: 6)

    @Invariant
    func countWithinBounds() -> Bool {
        queue.count >= 0 && queue.count <= queue.capacity // swiftlint:disable:this empty_count
    }

    @Command(weight: 3, #gen(.int(in: 0 ... 20)))
    mutating func put(value: Int) throws {
        guard queue.count < queue.capacity else { throw skip() }
        expected.append(value)
        queue.put(value)
    }

    @Command(weight: 3)
    mutating func get() throws {
        guard !queue.isEmpty else { throw skip() } // swiftlint:disable:this empty_count
        let expectedValue = expected.removeFirst()
        let actual = queue.get()
        try check(actual == expectedValue, "get must return elements in FIFO order")
    }

    @Command(weight: 1)
    mutating func size() throws {
        try check(queue.size == expected.count, "size must match model element count")
    }
}

// MARK: - Types

// A ring buffer with fixed capacity. All operations are correct except that
// `put` silently corrupts the stored value when the write pointer is at
// position 4 and the buffer is non-empty.

struct BuggyCircularQueue {
    private var buffer: [Int]
    private var readPos = 0
    private var writePos = 0
    private(set) var count = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        buffer = Array(repeating: 0, count: capacity)
    }

    mutating func put(_ value: Int) {
        // Bug: corrupts stored value when writePos == 2 and buffer is non-empty
        if writePos == 2, count > 0 { // swiftlint:disable:this empty_count
            buffer[writePos] = value &+ 1
        } else {
            buffer[writePos] = value
        }
        writePos = (writePos + 1) % capacity
        count += 1
    }

    mutating func get() -> Int {
        let value = buffer[readPos]
        readPos = (readPos + 1) % capacity
        count -= 1
        return value
    }

    var size: Int {
        count
    }

    var isEmpty: Bool {
        size == 0
    }
}
