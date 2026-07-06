import Foundation
import Testing
@testable import Exhaust

/// Deterministic logic tests for ``LaneRendezvous``.
///
/// Timing assertions discriminate code paths, not performance: tests that must distinguish release-by-arrival from release-by-budget-expiry use a 10-second budget, so any sub-second return proves the barrier released. The interleaving quality the barrier buys is validated operationally by the preemptive parity tests, not here.
@Suite("LaneRendezvous")
struct LaneRendezvousTests {
    /// Large enough that a spin-to-budget return cannot be mistaken for a barrier release on any machine.
    private static let unreachableBudget: UInt64 = 10_000_000_000

    @Test("A single-lane rendezvous does not wait")
    func singleLaneDoesNotWait() {
        let rendezvous = LaneRendezvous(laneCount: 1, spinBudgetNanoseconds: Self.unreachableBudget)
        let start = DispatchTime.now().uptimeNanoseconds
        rendezvous.arriveAndWait()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        #expect(elapsed < 1_000_000_000)
    }

    @Test("A lane whose sibling never arrives proceeds after the spin budget")
    func lonelyLaneProceedsAfterBudget() {
        let budget: UInt64 = 2_000_000
        let rendezvous = LaneRendezvous(laneCount: 2, spinBudgetNanoseconds: budget)
        let start = DispatchTime.now().uptimeNanoseconds
        rendezvous.arriveAndWait()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        #expect(elapsed >= budget)
    }

    @Test("The last arrival releases a waiting lane")
    func lastArrivalReleasesWaiter() async throws {
        let rendezvous = LaneRendezvous(laneCount: 2, spinBudgetNanoseconds: Self.unreachableBudget)
        let waiterElapsed = UnsafeSendableBox<UInt64?>(nil)

        DispatchQueue.global().async {
            let start = DispatchTime.now().uptimeNanoseconds
            rendezvous.arriveAndWait()
            waiterElapsed.value = DispatchTime.now().uptimeNanoseconds - start
        }
        try await waitFor("sibling arrival") {
            rendezvous.arrivedLaneCount >= 1
        }

        let start = DispatchTime.now().uptimeNanoseconds
        rendezvous.arriveAndWait()
        let lastArriverElapsed = DispatchTime.now().uptimeNanoseconds - start
        #expect(lastArriverElapsed < 1_000_000_000, "The last arriver takes the fast path and must not spin")

        try await waitFor("waiter departure") {
            waiterElapsed.value != nil
        }
        if let elapsed = waiterElapsed.value {
            #expect(elapsed < 1_000_000_000, "The waiter must be released by the arrival, not the 10s budget")
        }
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
