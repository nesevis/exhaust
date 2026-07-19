//
//  MetaFuzzProbe.swift
//  MetaFuzzProbe
//
//  Standalone self-fuzzing loop for the nightly CI wrapper. Runs as an executable so a trap in ExhaustCore kills only this process: the wrapper relaunches it, the run resumes from the progress log (EXHAUST_STATE_DIR), quarantines the crash region, and spends the remaining budget elsewhere. The main thread's 8 MB stack also tolerates deeper recipes than the 512 KiB test threads, which is why the depth and node-budget flags default higher here.
//

import ArgumentParser
import Exhaust
import ExhaustCore
import ExhaustMetaFuzz
import Foundation

@main
struct MetaFuzzProbe: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fuzzes the ExhaustCore pipeline against the oracle roster.",
        discussion: "Framework seams stay environment-driven: EXHAUST_STATE_DIR relocates the progress log and breadcrumb so the wrapper can resume a trapped run, and EXHAUST_RESUME=0 opts out of resuming. Exit codes: 0 = no findings, 2 = oracle violations found (records written), signal death = a trap in ExhaustCore."
    )

    @Option(help: "Fuzz budget in seconds.")
    var budgetSeconds: Int = 900

    @Option(help: "Pinned replay seed; omit for an unpinned run.")
    var seed: UInt64?

    @Option(help: "Recipe combinator nesting ceiling.")
    var depth: Int = 2

    @Option(help: "Recipe node-count ceiling. Calibrate raises with ExhaustStackProbe.")
    var nodeBudget: Int = 80

    @Option(help: "Directory for freeze-candidate records.")
    var findingsDirectory: String = "metafuzz-findings"

    func validate() throws {
        guard budgetSeconds > 0 else {
            throw ValidationError("--budget-seconds must be positive.")
        }
    }

    func run() throws {
        let findings = URL(fileURLWithPath: findingsDirectory)

        // The property must be a closure literal in each invocation: the macro's Void-closure handling is syntactic, and a function reference expands as if the property returned Bool.
        let report: FuzzReport
        if let seed {
            report = #explore(
                MetaFuzz.caseGenerator(maxDepth: depth, nodeBudget: nodeBudget),
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
        } else {
            report = #explore(
                MetaFuzz.caseGenerator(maxDepth: depth, nodeBudget: nodeBudget),
                time: .seconds(budgetSeconds)
            ) { fuzzCase in
                do {
                    try MetaFuzz.check(fuzzCase)
                } catch {
                    MetaFuzz.recordFinding(fuzzCase, violation: error, in: findings)
                    throw error
                }
            }
        }

        let percentage: (TimeSpan) -> String = { duration in
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

        if report.clusters.isEmpty {
            print("metafuzz: no findings in \(budgetSeconds)s")
            return
        }

        print("metafuzz: \(report.clusters.count) finding(s) — freeze candidates in \(findings.path)")
        for cluster in report.clusters {
            print("  - [\(cluster.symptoms.joined(separator: ", "))] \(cluster.reducedDescription)")
        }
        throw ExitCode(2)
    }
}
