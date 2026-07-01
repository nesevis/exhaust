// MEASUREMENT SCAFFOLDING — REMOVE BEFORE MERGE.
//
// Classifies preemptive probe timeouts to tell a thread-assignment timeout (the lanes never got
// scheduled, or got scheduled very late — a contention artifact under `swift test --parallel`) apart
// from a SUT-execution timeout (the lanes started promptly but a command did not return — a genuine
// slow/hung SUT). Output goes through `print` to stdout, NOT ExhaustLog, because ExhaustLog routes to
// oslog and would not appear in CI captured output.
//
// A summary line is printed every 100 timeouts and once more via atexit:
//   EXHAUST-TIMEOUT-STATS[TOTAL] probes=… timeouts=… unstartedLane=… allStarted=… latencyMs_p50=… …
// unstartedLane + high latency => thread-assignment; allStarted + low latency => SUT-execution.
import Foundation

final class PreemptiveTimeoutStats: @unchecked Sendable {
    static let shared = PreemptiveTimeoutStats()

    private let lock = NSLock()
    private var probes = 0
    private var timeouts = 0
    private var unstartedLaneTimeouts = 0
    private var allStartedTimeouts = 0
    private var latenciesMs: [Double] = []
    private var timeoutWallMs = 0.0
    private var atexitInstalled = false

    /// Counts one concurrent probe (the denominator for the timeout rate).
    func recordProbe() {
        lock.lock()
        probes += 1
        installAtexitLocked()
        lock.unlock()
    }

    /// Records a timed-out probe with the lane-scheduling evidence used to classify it.
    func recordTimeout(laneCount: Int, lanesStarted: Int, maxSchedLatencyMs: Double, idleTimeoutMs: Int) {
        lock.lock()
        timeouts += 1
        if lanesStarted < laneCount {
            unstartedLaneTimeouts += 1
        } else {
            allStartedTimeouts += 1
        }
        latenciesMs.append(maxSchedLatencyMs)
        timeoutWallMs += Double(idleTimeoutMs)
        let shouldPrintProgress = timeouts % 100 == 0
        lock.unlock()
        if shouldPrintProgress {
            printSummary(tag: "PROGRESS")
        }
    }

    func printSummary(tag: String) {
        lock.lock()
        let sorted = latenciesMs.sorted()
        let line = "EXHAUST-TIMEOUT-STATS[\(tag)] probes=\(probes) timeouts=\(timeouts) unstartedLane=\(unstartedLaneTimeouts) allStarted=\(allStartedTimeouts) latencyMs_p50=\(fmt(percentile(sorted, 0.50))) latencyMs_p99=\(fmt(percentile(sorted, 0.99))) latencyMs_max=\(fmt(sorted.last ?? 0)) timeoutWallMs=\(Int(timeoutWallMs))"
        lock.unlock()
        print(line)
    }

    private func installAtexitLocked() {
        guard atexitInstalled == false else {
            return
        }
        atexitInstalled = true
        // Non-capturing (references only a global static), so it converts to the C function atexit expects.
        atexit {
            PreemptiveTimeoutStats.shared.printSummary(tag: "TOTAL")
        }
    }

    private func percentile(_ sorted: [Double], _ quantile: Double) -> Double {
        guard sorted.isEmpty == false else {
            return 0
        }
        let index = min(sorted.count - 1, Int((Double(sorted.count) * quantile).rounded(.down)))
        return sorted[index]
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

/// Computes lanes-started and max scheduling latency from per-lane start stamps and forwards them to the aggregator.
func recordPreemptiveTimeout(
    laneStartedAt: [UnsafeSendableBox<UInt64?>],
    submittedAt: UInt64,
    idleTimeoutMs: Int
) {
    let started = laneStartedAt.compactMap(\.value)
    let maxSchedLatencyMs = started.map { Double($0 &- submittedAt) / 1_000_000 }.max() ?? 0
    PreemptiveTimeoutStats.shared.recordTimeout(
        laneCount: laneStartedAt.count,
        lanesStarted: started.count,
        maxSchedLatencyMs: maxSchedLatencyMs,
        idleTimeoutMs: idleTimeoutMs
    )
}
