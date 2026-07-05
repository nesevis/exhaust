import Foundation

/// Monotonic wall-clock timer for self-timed benchmarks. `ContinuousClock` needs macOS 13 and this target's floor is macOS 10.15, so timing goes through `DispatchTime`.
struct BenchmarkTimer {
    private let start = DispatchTime.now()

    var elapsedMs: Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
    }

    var elapsedSeconds: Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    }
}

/// Formats a millisecond count the way the uniqueness tables expect: "735ms" below one second, "2.41s" above.
func formatBenchmarkMs(_ ms: Double) -> String {
    if ms < 1000 {
        return String(format: "%.0fms", ms)
    } else {
        return String(format: "%.2fs", ms / 1000)
    }
}
