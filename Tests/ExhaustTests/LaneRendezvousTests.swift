import Foundation
import Testing
@testable import Exhaust

/// Deterministic logic tests for ``LaneRendezvous``.
///
/// The interleaving quality the barrier buys is validated operationally by the preemptive parity tests, not here. Without a departure-reason return, the tests discriminate release-by-arrival from budget expiry by elapsed time against a deliberately oversized budget: a departure well under the budget can only be a release.
@Suite("LaneRendezvous")
struct LaneRendezvousTests {
    /// Large enough that any departure observed within the test's lifetime must be a release by arrival, not budget expiry.
    private static let unreachableBudget: UInt64 = 10_000_000_000

    @Test("A single-lane rendezvous does not wait")
    func singleLaneDoesNotWait() {
        let rendezvous = LaneRendezvous(laneCount: 1, spinBudgetNanoseconds: Self.unreachableBudget)
        let start = DispatchTime.now().uptimeNanoseconds
        rendezvous.arriveAndWait()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        #expect(elapsed < Self.unreachableBudget, "A lone lane is its own last arrival and must not spin")
    }

    @Test("A lane whose sibling never arrives proceeds after the spin budget")
    func lonelyLaneProceedsAfterBudget() {
        let budget: UInt64 = 2_000_000
        let rendezvous = LaneRendezvous(laneCount: 2, spinBudgetNanoseconds: budget)
        let start = DispatchTime.now().uptimeNanoseconds
        rendezvous.arriveAndWait()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        #expect(elapsed >= budget, "With no sibling, the only legitimate way out is exhausting the budget")
    }

    @Test("The last arrival releases a waiting lane")
    func lastArrivalReleasesWaiter() async throws {
        let rendezvous = LaneRendezvous(laneCount: 2, spinBudgetNanoseconds: Self.unreachableBudget)
        let releaserPolling = SendableBox(false)
        let waiterElapsed = SendableBox<UInt64?>(nil)

        // The releaser arrives in reaction to observing the waiter, and is confirmed to be polling before the waiter is dispatched. The waiter's budget window therefore contains only a live thread's poll quantum, never thread-spawn or cooperative-wakeup latency: on a saturated runner the test task can be descheduled arbitrarily long without the budget expiring, because the clock only starts once the release is already armed.
        DispatchQueue.global().async {
            releaserPolling.value = true
            while rendezvous.arrivedLaneCount < 1 {
                Thread.sleep(forTimeInterval: 0.000_1)
            }
            rendezvous.arriveAndWait()
        }
        try await waitFor("releaser polling") {
            releaserPolling.value
        }

        DispatchQueue.global().async {
            let start = DispatchTime.now().uptimeNanoseconds
            rendezvous.arriveAndWait()
            waiterElapsed.value = DispatchTime.now().uptimeNanoseconds - start
        }
        try await waitFor("waiter departure") {
            waiterElapsed.value != nil
        }
        let elapsed = try #require(waiterElapsed.value)
        #expect(elapsed < Self.unreachableBudget, "The waiter must be released by the arrival, not the budget")
    }

    @Test("All lanes depart when every lane arrives")
    func allLanesDepartTogether() async throws {
        let laneCount = 3
        let rendezvous = LaneRendezvous(laneCount: laneCount, spinBudgetNanoseconds: Self.unreachableBudget)
        let departedCount = UnsafeSendableBox(0)
        let countLock = NSLock()

        for _ in 0 ..< laneCount {
            DispatchQueue.global().async {
                rendezvous.arriveAndWait()
                countLock.withLocking {
                    departedCount.value += 1
                }
            }
        }
        try await waitFor("all lanes to depart") {
            countLock.withLocking { departedCount.value } == laneCount
        }
    }
}

// MARK: - Helpers

/// Polls until `condition` holds, or records a failure after a bounded wait. Conditions settle within microseconds of the involved threads being scheduled; the cap only guards against a broken barrier wedging the test.
private func waitFor(
    _ label: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    condition: () -> Bool
) async throws {
    for _ in 0 ..< 2000 {
        if condition() {
            return
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    Issue.record("Timed out waiting for \(label)", sourceLocation: sourceLocation)
}
