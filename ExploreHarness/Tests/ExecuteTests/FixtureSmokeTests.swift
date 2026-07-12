import ExecuteFixture
import Testing

@Suite("Fixture reproducer smoke tests")
struct FixtureSmokeTests {
    // MARK: - Fault A (accumulation, hwm >= capacity)

    @Test("Fault A fires at the default capacity after 24 enqueues (registry minimal)")
    func faultAMinimalAtDefaultCapacity() {
        var queue = BoundedQueue()
        for i in 0 ..< 24 {
            _ = queue.enqueue(i)
        }
        #expect(queue.elements[0] == -999, "the ground-truth registry's minimal sequence at the default capacity should fire fault A")
    }

    @Test("Fault A fires on 32 enqueues without reset")
    func faultAMinimal() {
        var queue = BoundedQueue(capacity: 32)
        for i in 0 ..< 32 {
            _ = queue.enqueue(i)
        }
        #expect(queue.elements[0] == -999, "Fault A should corrupt elements[0]")
    }

    @Test("Fault A does not fire on 31 enqueues (strict prefix)")
    func faultAPrefixSafe() {
        var queue = BoundedQueue(capacity: 32)
        for i in 0 ..< 31 {
            _ = queue.enqueue(i)
        }
        #expect(queue.elements[0] == 0, "31 enqueues should not trigger fault A")
    }

    @Test("Fault A does not fire when a dequeue intervenes")
    func faultAResetByDequeue() throws {
        var queue = BoundedQueue(capacity: 32)
        for i in 0 ..< 31 {
            _ = queue.enqueue(i)
        }
        _ = try queue.dequeue()
        _ = queue.enqueue(99)
        _ = queue.enqueue(100)
        #expect(queue.elements.contains(-999) == false, "dequeue resets hwm; fault A should not fire")
    }

    @Test("Fault A minimal does not trigger fault S")
    func faultADoesNotTriggerS() {
        var queue = BoundedQueue(capacity: 32)
        for i in 0 ..< 32 {
            _ = queue.enqueue(i)
        }
        #expect(queue.elements[0] == -999, "only fault A's corruption is present")
        #expect(queue.count == 32)
    }

    @Test("Fault A minimal does not trigger fault P")
    func faultADoesNotTriggerP() throws {
        var queue = BoundedQueue(capacity: 32)
        for i in 0 ..< 32 {
            _ = queue.enqueue(i)
        }
        let peeked = try queue.peekTracked()
        #expect(peeked == -999)
    }

    // MARK: - Fault S (clear when non-empty, twice)

    @Test("Fault S fires on two clear-when-nonempty events")
    func faultSMinimal() {
        var queue = BoundedQueue(capacity: 8)
        _ = queue.enqueue(0)
        queue.clear()
        _ = queue.enqueue(0)
        queue.clear()
        // After the second clear-when-nonempty, elements is set to [-888].
        #expect(queue.elements == [-888], "Fault S should set elements to [-888]")
    }

    @Test("Fault S does not fire on one clear-when-nonempty (strict prefix)")
    func faultSPrefixSafe() {
        var queue = BoundedQueue(capacity: 8)
        _ = queue.enqueue(0)
        queue.clear()
        #expect(queue.elements.isEmpty, "one clear-when-nonempty should not trigger fault S")
    }

    @Test("Fault S does not trigger fault A")
    func faultSDoesNotTriggerA() {
        var queue = BoundedQueue(capacity: 8)
        _ = queue.enqueue(0)
        queue.clear()
        _ = queue.enqueue(0)
        queue.clear()
        // A fires when hwm >= 8; clear resets hwm, so it never climbs.
        #expect(queue.elements.contains(-999) == false)
    }

    @Test("Fault S does not trigger fault P")
    func faultSDoesNotTriggerP() {
        var queue = BoundedQueue(capacity: 8)
        _ = queue.enqueue(0)
        queue.clear()
        _ = queue.enqueue(0)
        queue.clear()
        // P fires on peekAtCountOne >= 3; no peek in S's minimal.
        #expect(queue.elements == [-888])
    }

    // MARK: - Fault P (peek at count 1, three times)

    @Test("Fault P fires on three peekTracked-at-count-1 events")
    func faultPMinimal() throws {
        var queue = BoundedQueue(capacity: 8)
        _ = queue.enqueue(0)
        _ = try queue.peekTracked()
        _ = try queue.peekTracked()
        do {
            _ = try queue.peekTracked()
            Issue.record("Third peekTracked at count 1 should throw corruption")
        } catch BoundedQueueError.corruption {
            // Expected.
        }
    }

    @Test("Fault P does not fire on two peekTracked-at-count-1 (strict prefix)")
    func faultPPrefixSafe() throws {
        var queue = BoundedQueue(capacity: 8)
        _ = queue.enqueue(0)
        _ = try queue.peekTracked()
        _ = try queue.peekTracked()
        // No throw on the second peek — threshold is 3.
    }

    @Test("Fault P does not trigger fault A")
    func faultPDoesNotTriggerA() throws {
        var queue = BoundedQueue(capacity: 8)
        _ = queue.enqueue(0)
        _ = try queue.peekTracked()
        _ = try queue.peekTracked()
        // A fires when hwm >= 8; only 1 enqueue here, hwm = 1.
        #expect(queue.elements.contains(-999) == false)
    }

    @Test("Fault P does not trigger fault S")
    func faultPDoesNotTriggerS() throws {
        var queue = BoundedQueue(capacity: 8)
        _ = queue.enqueue(0)
        _ = try queue.peekTracked()
        _ = try queue.peekTracked()
        // S fires on clearWhenNonEmpty >= 2; no clear in P's minimal.
        #expect(queue.elements == [0])
    }

    // MARK: - Shared Symptom

    @Test("Fault S corrupts data and fault P throws, both surfacing as corruption")
    func sharedSymptom() {
        // S manifests as data corruption (elements set to [-888]) caught by the model invariant.
        var queueS = BoundedQueue(capacity: 8)
        _ = queueS.enqueue(0)
        queueS.clear()
        _ = queueS.enqueue(0)
        queueS.clear()
        #expect(queueS.elements == [-888], "Fault S should corrupt elements to [-888]")

        // P throws corruption directly on the third peek at count 1.
        var queueP = BoundedQueue(capacity: 8)
        _ = queueP.enqueue(0)
        #expect(throws: BoundedQueueError.corruption) {
            _ = try queueP.peekTracked()
            _ = try queueP.peekTracked()
            _ = try queueP.peekTracked()
        }
    }
}
