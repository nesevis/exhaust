import Foundation
import Testing
@testable import Exhaust

/// Deterministic scripted logic tests for ``LaneGate``'s admission bookkeeping.
///
/// These make no timing assumptions and spawn no real threads: each waits for a waiter to park (bounded poll on `waiterCount`), then asserts a state that `release` settles synchronously. The concurrency behavior under real parallel load is validated operationally by the suite's own wall-clock, not here.
@Suite("LaneGate")
struct LaneGateTests {
    @Test("Budget clamps up to the reservation floor")
    func floorClamp() {
        #expect(LaneGate(limit: 2).limit == LaneGate.reservationFloor)
        #expect(LaneGate(limit: 0).limit == LaneGate.reservationFloor)
        #expect(LaneGate(limit: 10).limit == 10)
    }

    @Test("Fast path reserves and releases without parking")
    func fastPath() async {
        let gate = LaneGate(limit: 8)
        await gate.acquire(3)
        #expect(gate.freeCount == 5)
        #expect(gate.waiterCount == 0)
        gate.release(3)
        #expect(gate.freeCount == 8)
    }

    @Test("A request that does not fit takes nothing until it fits")
    func atomicAllOrNothing() async throws {
        let gate = LaneGate(limit: 5)
        await gate.acquire(3)
        #expect(gate.freeCount == 2)

        // Needs 3, only 2 free: it must park without partially deducting.
        let pending = Task { await gate.acquire(3) }
        try await waitForWaiters(gate, count: 1)
        #expect(gate.freeCount == 2)

        // Freeing to 5 admits the whole request, leaving 2.
        gate.release(3)
        await pending.value
        #expect(gate.freeCount == 2)
        #expect(gate.waiterCount == 0)
    }

    @Test("A large request holds the line against a later small one")
    func fifoLargeRequestHoldsTheLine() async throws {
        let gate = LaneGate(limit: 5)
        await gate.acquire(5)
        let order = OrderRecorder()

        let big = Task { await gate.acquire(5); order.record(5) }
        try await waitForWaiters(gate, count: 1)
        let small = Task { await gate.acquire(1); order.record(1) }
        try await waitForWaiters(gate, count: 2)

        // One lane back: the head (5) does not fit, and the trailing 1 may not leapfrog it. `release` settles synchronously, so both are still parked when it returns.
        gate.release(1)
        #expect(gate.freeCount == 1)
        #expect(gate.waiterCount == 2)
        #expect(order.snapshot() == [])

        // Four more (5 free): the head 5 admits and consumes everything, so the 1 still cannot.
        gate.release(4)
        #expect(gate.waiterCount == 1)
        await big.value
        #expect(order.snapshot() == [5])

        // Releasing the big run's lanes finally admits the 1.
        gate.release(5)
        await small.value
        #expect(order.snapshot() == [5, 1])
        #expect(gate.waiterCount == 0)
    }

    @Test("Reservation sizes: async threads adds the coordinator lane")
    func reservationSizes() {
        #expect(LaneReservation.threads(4) == 5)
        #expect(LaneReservation.single == 1)
    }
}

// MARK: - Helpers

/// Spins until at least `count` runs have parked at the gate, or records a failure after a bounded wait. The park happens within microseconds of the child task being scheduled; the cap only guards against a lost wakeup wedging the test.
private func waitForWaiters(
    _ gate: LaneGate,
    count: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    for _ in 0 ..< 2000 {
        if gate.waiterCount >= count {
            return
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    Issue.record("Timed out waiting for \(count) waiters (have \(gate.waiterCount))", sourceLocation: sourceLocation)
}

/// Records admission order across concurrent tasks under a lock.
private final class OrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func record(_ value: Int) {
        lock.withLocking { values.append(value) }
    }

    func snapshot() -> [Int] {
        lock.withLocking { values }
    }
}
