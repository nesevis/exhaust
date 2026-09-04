import Foundation
import Testing
@testable import ExhaustCore

/// The process-global comparison ring under the concurrent access it is built for: the inline-8bit-counter model has no per-run context, so every thread of an instrumented system under test writes to one ring while the run's lane drains it.
///
/// Run under ThreadSanitizer (`swift test --sanitize=thread`) to check the exclusion itself; without it these still pin the observable contract, which is that a drain returns whole records and never a mix of two.
@Suite("Comparison ring under concurrent writers", .serialized)
struct ComparisonRingConcurrencyTests {
    @Test("A drain concurrent with several writers returns only whole records")
    func concurrentWritersYieldWholeRecords() {
        ComparisonRuntime.reset()
        ComparisonRuntime.setEnabled(true)
        defer {
            ComparisonRuntime.setEnabled(false)
            ComparisonRuntime.reset()
        }

        // Each writer pairs a value with itself, so any record whose two operands disagree is a torn one.
        let writerCount = 4
        let group = DispatchGroup()
        for writer in 1 ... writerCount {
            DispatchQueue.global().async(group: group) {
                for _ in 0 ..< 2000 {
                    TracePCGuardCoverageSource.fireComparisonForTesting(UInt64(writer), UInt64(writer))
                }
            }
        }

        var drains = 0
        var torn = 0
        while group.wait(timeout: .now()) == .timedOut {
            drains += 1
            ComparisonRuntime.forEachRecord { _, first, second in
                if first != second {
                    torn += 1
                }
            }
        }
        group.wait()

        #expect(torn == 0)
        #expect(drains > 0, "the writers finished before a single drain ran, so nothing was exercised concurrently")
        // Without this the assertions above hold vacuously on a ring that recorded nothing.
        #expect(ComparisonRuntime.recordCount() > 0)
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
