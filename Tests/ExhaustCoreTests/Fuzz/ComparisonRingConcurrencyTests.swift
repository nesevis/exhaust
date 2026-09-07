import Foundation
import Testing
@testable import ExhaustCore

/// The process-global comparison ring under the concurrent access it is built for: the inline-8bit-counter model has no per-run context, so every thread of an instrumented system under test writes to one ring while the run's lane drains it.
///
/// Not a `.threads` spec: that mode replays every candidate ordering on a fresh instance of the system under test, and the ring is a process singleton with no fresh instance to give it. The property is stated directly instead, using dedicated writer threads so their progress never depends on spare capacity in the same GCD pool as the waiting test runner.
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

        // Each writer pairs a value with itself, so any record whose two operands disagree is a torn one. A concurrentPerform iteration must not wait for its siblings — libdispatch may run them serially — so writers get dedicated threads and the test thread remains the drainer.
        let ready = DispatchGroup()
        let finished = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        let torn = SendableBox(0)
        var writerThreads: [Thread] = []
        for writer in 1 ... writers {
            ready.enter()
            finished.enter()
            let thread = Thread {
                ready.leave()
                start.wait()
                for _ in 0 ..< recordsPerWriter {
                    TracePCGuardCoverageSource.fireComparisonForTesting(UInt64(writer), UInt64(writer))
                }
                finished.leave()
            }
            writerThreads.append(thread)
            thread.start()
        }
        ready.wait()
        for _ in 0 ..< writers {
            start.signal()
        }

        repeat {
            ComparisonRuntime.forEachRecord { _, first, second in
                if first != second {
                    torn.withValue { $0 += 1 }
                }
            }
            // The ring uses a deliberately tiny spin lock. Backing off keeps this stress reader from unfairly reacquiring it before a writer can make progress.
            Thread.sleep(forTimeInterval: 0.0001)
        } while finished.wait(timeout: .now()) == .timedOut
        withExtendedLifetime(writerThreads) {
            // The last snapshot is after every writer, so it observes the settled ring.
            ComparisonRuntime.forEachRecord { _, first, second in
                if first != second {
                    torn.withValue { $0 += 1 }
                }
            }
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
