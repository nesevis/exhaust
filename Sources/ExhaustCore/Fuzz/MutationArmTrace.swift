// Per-window snapshots of the mutation-arm ledger, for offline analysis of how arm productivity moves during a run.
//
// The ledger a run returns is cumulative, so it answers what an arm did over the whole run and nothing about when. Two questions need the shape rather than the total: whether an arm's admission rate decays as the corpus saturates, and whether the ranking of arms by admission rate in one window predicts the next. Both are computed offline from these rows, against a within-window control that splits one window's attempts by parity.
//
// The trace is off unless `EXHAUST_ARM_TRACE` names a directory. With it unset the runner holds nil and the per-attempt cost is one optional test.

import Foundation

/// Appends per-window mutation-arm counts to a CSV file, one row per arm per window.
///
/// One file per process, appended across every run in it: a harness may drive many runs from one process, and a file per run would need the runner to know which run it is, which it does not. Rows arrive in run order and each run's window column starts at zero, so a window index that does not increase marks the boundary between two runs.
///
/// Rows are written at window boundaries rather than buffered to the end of the run, so a task that crashes or runs out of budget still leaves everything it recorded.
package struct MutationArmTrace {
    private let path: String
    private let windowSize: Int
    private let seed: UInt64
    /// The next window boundary, in attempts, or nil until the first row anchors it.
    private var nextBoundary: Int?
    private var windowIndex = 0

    /// Creates a trace writing under `directory`, or nil when the environment did not ask for one.
    ///
    /// - Parameters:
    ///   - directory: The directory to write into, from `EXHAUST_ARM_TRACE`. Created when absent.
    ///   - windowSize: Attempts per window, from `EXHAUST_ARM_TRACE_WINDOW`.
    ///   - seed: The run's seed, recorded on every row so a shard's rows can be attributed without reading the log beside them.
    package init?(directory: String?, windowSize: Int, seed: UInt64) {
        guard let directory, windowSize > 0 else {
            return nil
        }
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        path = directory + "/arm-trace-\(ProcessInfo.processInfo.processIdentifier).csv"
        self.windowSize = windowSize
        self.seed = seed
    }

    /// Writes one window when `attemptIndex` reaches the next boundary, and does nothing otherwise.
    ///
    /// Called once per evaluated attempt, so the common path is a single integer comparison.
    package mutating func note(
        attemptIndex: Int,
        ledger: MutationArmLedger,
        bandit: MutationBandit,
        admissible: MutationArmSet = .all,
        diagnostics: FuzzDiagnostics? = nil
    ) {
        guard let boundary = nextBoundary else {
            // Anchored on the first row rather than at init. Attempts are numbered on the runner's logical timeline, which a resumed run starts at its predecessors' total, and the runner does not know that total until recovery has restored.
            nextBoundary = windowBoundary(after: attemptIndex)
            return
        }
        guard attemptIndex >= boundary else {
            return
        }
        // Read here rather than at the call, so the two histogram walks are paid once per window rather than once per attempt.
        let spacingMedian = diagnostics?.admissionSpacingQuantile(0.5) ?? 0
        let spacingUpper = diagnostics?.admissionSpacingQuantile(0.9) ?? 0
        var rows = ""
        for arm in MutationArm.allCases {
            rows += "\(seed),\(windowIndex),\(attemptIndex),\(arm),"
            rows += "\(ledger.draws(arm: arm)),\(ledger.misses(arm: arm)),"
            rows += "\(ledger.count(arm: arm)),\(ledger.admissions(arm: arm)),"
            rows += "\(ledger.creditedEven(arm: arm)),\(ledger.admissionsEven(arm: arm)),"
            rows += "\(bandit.probability(of: arm)),"
            rows += "\(admissible.contains(arm) ? 1 : 0),"
            rows += "\(spacingMedian),\(spacingUpper)\n"
        }
        append(rows)
        windowIndex += 1
        nextBoundary = windowBoundary(after: attemptIndex)
    }

    /// The first boundary strictly after `attemptIndex`.
    ///
    /// Every boundary the timeline has already passed is skipped rather than closed in turn. Not every attempt reaches ``note(attemptIndex:ledger:bandit:admissible:diagnostics:)`` — a recent duplicate or a candidate the materializer rejects advances the timeline without one — so a gap can span several windows, and stepping one window per call would answer it with a run of catch-up rows on consecutive evaluations, each a synchronous write, describing windows no row can distinguish.
    private func windowBoundary(after attemptIndex: Int) -> Int {
        attemptIndex - attemptIndex % windowSize + windowSize
    }

    /// Appends one window's rows, creating the file with its header on the first write of the process.
    ///
    /// Failures are swallowed: the trace is a measurement aid, and a run that cannot write it should still finish its search rather than fail the property under test.
    private func append(_ rows: String) {
        let manager = FileManager.default
        if manager.fileExists(atPath: path) == false {
            let header = "seed,window,attempts,arm,draws,misses,credited,admissions,creditedEven,admissionsEven,probability,admissible,spacingMedian,spacingP90\n"
            manager.createFile(atPath: path, contents: Data(header.utf8))
        }
        guard let handle = FileHandle(forWritingAtPath: path) else {
            return
        }
        defer {
            handle.closeFile()
        }
        // The throwing seek and write need macOS 10.15.4, above this module's floor.
        handle.seekToEndOfFile()
        handle.write(Data(rows.utf8))
    }
}
