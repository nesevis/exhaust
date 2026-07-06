import Foundation
import Testing
@testable import Exhaust

/// Deterministic logic tests for ``LaneRendezvous``.
///
/// The interleaving quality the barrier buys is validated operationally by the preemptive parity tests, not here.
@Suite("LaneRendezvous")
struct LaneRendezvousTests {
    /// Large enough that a waiter should still be spinning when the sibling lane arrives.
    private static let unreachableBudget: UInt64 = 10_000_000_000

    @Test("A single-lane rendezvous does not wait")
    func singleLaneDoesNotWait() {
        let rendezvous = LaneRendezvous(laneCount: 1, spinBudgetNanoseconds: Self.unreachableBudget)
        let departureReason = rendezvous.arriveAndWait()
        #expect(departureReason == .allLanesArrived)
    }

    @Test("A lane whose sibling never arrives proceeds after the spin budget")
    func lonelyLaneProceedsAfterBudget() {
        let budget: UInt64 = 2_000_000
        let rendezvous = LaneRendezvous(laneCount: 2, spinBudgetNanoseconds: budget)
        let departureReason = rendezvous.arriveAndWait()
        #expect(departureReason == .spinBudgetExceeded)
    }

    @Test("The last arrival releases a waiting lane")
    func lastArrivalReleasesWaiter() async throws {
        let rendezvous = LaneRendezvous(laneCount: 2, spinBudgetNanoseconds: Self.unreachableBudget)
        let waiterDepartureReason = SendableBox<LaneRendezvous.DepartureReason?>(nil)

        DispatchQueue.global().async {
            waiterDepartureReason.value = rendezvous.arriveAndWait()
        }
        try await waitFor("sibling arrival") {
            rendezvous.arrivedLaneCount >= 1
        }

        let lastArriverDepartureReason = rendezvous.arriveAndWait()
        #expect(lastArriverDepartureReason == .allLanesArrived)

        try await waitFor("waiter departure") {
            waiterDepartureReason.value != nil
        }
        #expect(waiterDepartureReason.value == .allLanesArrived, "The waiter must be released by the arrival, not the 10s budget")
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
