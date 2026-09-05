import Foundation
import Testing
@testable import ExhaustCore

/// The process-global comparison ring under the concurrent access it is built for: the inline-8bit-counter model has no per-run context, so every thread of an instrumented system under test writes to one ring while the run's lane drains it.
///
/// Not a `.threads` spec: that mode replays every candidate ordering on a fresh instance of the system under test, and the ring is a process singleton with no fresh instance to give it. The property is stated directly instead, over `concurrentPerform`, which returns only when every writer and the drainer have finished, so the outcome is decided before anything is asserted and no wall clock is involved.
///
/// Run under ThreadSanitizer (`swift test --sanitize=thread`) to check the exclusion itself; without it these still pin the observable contract, which is that a drain returns whole records and never a mix of two.
@Suite("Comparison ring under concurrent writers", .serialized)
struct ComparisonRingConcurrencyTests {
    @Test(
        "A drain concurrent with several writers returns only whole records",
        arguments: [(writers: 1, recordsPerWriter: 50), (writers: 4, recordsPerWriter: 500), (writers: 8, recordsPerWriter: 2000)]
    )
    func concurrentWritersYieldWholeRecords(writers: Int, recordsPerWriter: Int) {
        ComparisonRuntime.reset()
        ComparisonRuntime.setEnabled(true)
        defer {
            ComparisonRuntime.setEnabled(false)
            ComparisonRuntime.reset()
        }

        // Each writer pairs a value with itself, so any record whose two operands disagree is a torn one. The drainer keeps draining while any writer is still going and once more after the last one finishes, so every run drains at least once and the final count is the whole ring.
        let writersRemaining = SendableBox(writers)
        let torn = SendableBox(0)
        DispatchQueue.concurrentPerform(iterations: writers + 1) { iteration in
            guard iteration > 0 else {
                repeat {
                    ComparisonRuntime.forEachRecord { _, first, second in
                        if first != second {
                            torn.withValue { $0 += 1 }
                        }
                    }
                } while writersRemaining.value > 0
                return
            }
            for _ in 0 ..< recordsPerWriter {
                TracePCGuardCoverageSource.fireComparisonForTesting(UInt64(iteration), UInt64(iteration))
            }
            writersRemaining.withValue { $0 -= 1 }
        }

        #expect(torn.value == 0)
        // The drainer's last pass ran after every writer finished, so the ring holds every record up to its capacity; anything less means a store was lost.
        #expect(ComparisonRuntime.recordCount() == min(writers * recordsPerWriter, 4096))
    }

    @Test("Disabling stops recording, and a drain after it sees a settled ring")
    func disablingSettlesTheRing() {
        ComparisonRuntime.reset()
        ComparisonRuntime.setEnabled(true)
        TracePCGuardCoverageSource.fireComparisonForTesting(7, 7)
        ComparisonRuntime.setEnabled(false)

        // Clearing the flag is not on its own a fence for a writer already inside the critical section; the drain takes the ring's lock, which is what settles it.
        let settled = ComparisonRuntime.recordCount()
        TracePCGuardCoverageSource.fireComparisonForTesting(9, 9)
        #expect(ComparisonRuntime.recordCount() == settled)

        ComparisonRuntime.reset()
        #expect(ComparisonRuntime.recordCount() == 0)
    }
}
