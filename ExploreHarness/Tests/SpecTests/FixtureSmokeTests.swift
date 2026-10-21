import SpecFixture
import Testing

@Suite("Fixture reproducer smoke tests")
struct FixtureSmokeTests {
    @Test("The registry's default queue capacity is 24")
    func defaultCapacity() {
        #expect(BoundedQueue().capacity == 24)
    }

    @Test("Fault A fires at capacity, after a safe prefix", arguments: [24, 32])
    func faultAThreshold(capacity: Int) throws {
        var queue = BoundedQueue(capacity: capacity)
        for value in 0 ..< capacity - 1 {
            _ = queue.enqueue(value)
        }
        #expect(queue.elements == Array(0 ..< capacity - 1))
        _ = queue.enqueue(capacity - 1)
        #expect(queue.elements[0] == -999)
        #expect(queue.count == capacity)
        #expect(try queue.peekTracked() == -999)
    }

    @Test("Fault A does not fire when a dequeue intervenes")
    func faultAResetByDequeue() throws {
        var queue = BoundedQueue(capacity: 32)
        for value in 0 ..< 31 {
            _ = queue.enqueue(value)
        }
        _ = try queue.dequeue()
        _ = queue.enqueue(99)
        _ = queue.enqueue(100)
        #expect(queue.elements.contains(-999) == false, "dequeue resets the high-water mark")
    }

    @Test("Fault S corrupts only the second clear of a nonempty queue")
    func faultSThreshold() {
        var queue = BoundedQueue(capacity: 8)
        _ = queue.enqueue(0)
        queue.clear()
        #expect(queue.elements.isEmpty)
        _ = queue.enqueue(0)
        queue.clear()
        #expect(queue.elements == [-888])
    }

    @Test("Fault P throws corruption only on the third peek at count one")
    func faultPThreshold() throws {
        var queue = BoundedQueue(capacity: 8)
        _ = queue.enqueue(0)
        #expect(try queue.peekTracked() == 0)
        #expect(try queue.peekTracked() == 0)
        #expect(queue.elements == [0])
        #expect(throws: BoundedQueueError.corruption) {
            _ = try queue.peekTracked()
        }
    }
}
