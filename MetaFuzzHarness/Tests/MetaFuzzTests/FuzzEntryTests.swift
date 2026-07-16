import Exhaust
import ExhaustMetaFuzz
import Foundation
import Testing

/// The instrumented fuzz entry for the CI PR lane. Gated on `METAFUZZ_FUZZ=1` because `#explore(time:)` hard-fails without coverage instrumentation, and this package's default `swift test` run is uninstrumented — the CI lane builds with `-Xswiftc -sanitize=undefined -Xswiftc -sanitize-coverage=edge,inline-8bit-counters,pc-table` and sets the variable.
@Suite("Fuzz entry", .enabled(if: ProcessInfo.processInfo.environment["METAFUZZ_FUZZ"] == "1"))
struct FuzzEntryTests {
    @Test("The pipeline holds under a short pinned fuzz run")
    func pipelineHoldsUnderFuzzing() {
        let budgetSeconds = ProcessInfo.processInfo.environment["METAFUZZ_BUDGET"].flatMap(Int.init) ?? 60
        let seed = ProcessInfo.processInfo.environment["METAFUZZ_SEED"].flatMap(UInt64.init) ?? 1
        let findings = findingsDirectory()

        let report = #explore(
            MetaFuzz.caseGenerator(),
            time: .seconds(budgetSeconds),
            .replay(.numeric(seed))
        ) { fuzzCase in
            do {
                try MetaFuzz.check(fuzzCase)
            } catch {
                MetaFuzz.recordFinding(fuzzCase, violation: error, in: findings)
                throw error
            }
        }

        printProbeMetrics(report)

        #expect(
            report.clusters.isEmpty,
            "Engine defects found — freeze candidates written to \(findings.path): \(report.clusters.map(\.reducedDescription))"
        )
    }
}

private func printProbeMetrics(_ report: FuzzReport) {
    let percentage: (TimeBudget) -> String = { duration in
        guard report.elapsed.nanoseconds > 0 else {
            return "0.0"
        }
        return String(format: "%.1f", duration.seconds / report.elapsed.seconds * 100)
    }
    let timing = report.timing
    print(
        "metafuzz: probe throughput \(String(format: "%.1f", report.attemptsPerSecond)) evaluated cases/s "
            + "(\(report.evaluatedSearchCases) cases); property \(percentage(timing.property))% · "
            + "screening \(percentage(timing.screeningOverhead))% · "
            + "sampling \(percentage(timing.samplingOverhead))% · "
            + "mutation \(percentage(timing.mutationOverhead))% · "
            + "reduction \(percentage(timing.reduction))% · other \(percentage(timing.other))%"
    )
}

// MARK: - Findings Directory

/// Where violating cases land as freeze-candidate records. CI uploads this directory as an artifact; the default keeps local runs inside the package's gitignored build directory.
private func findingsDirectory() -> URL {
    if let override = ProcessInfo.processInfo.environment["METAFUZZ_FINDINGS"] {
        return URL(fileURLWithPath: override)
    }
    return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(".build/metafuzz-findings")
}
