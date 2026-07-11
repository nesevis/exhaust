//
//  main.swift
//  MetaFuzzProbe
//
//  Standalone self-fuzzing loop for the nightly CI wrapper. Runs as an executable so a trap in ExhaustCore kills only this process: the wrapper relaunches it, the run resumes from the progress log (EXHAUST_STATE_DIR), quarantines the crash region, and spends the remaining budget elsewhere. The main thread's 8 MB stack also tolerates deeper recipes than the 512 KiB test threads, which is why the depth and node-budget knobs default higher here.
//
//  Environment:
//    METAFUZZ_BUDGET      fuzz budget in seconds (default 900)
//    METAFUZZ_SEED        pinned replay seed; unset = unpinned
//    METAFUZZ_DEPTH       recipe combinator nesting ceiling (default 2)
//    METAFUZZ_NODE_BUDGET recipe node-count ceiling (default 80; calibrate raises with ExhaustStackProbe)
//    METAFUZZ_FINDINGS    directory for freeze-candidate records (default ./metafuzz-findings)
//
//  Exit codes: 0 = no findings, 2 = oracle violations found (records written), traps = signal death.
//

import Exhaust
import ExhaustCore
import ExhaustMetaFuzz
import Foundation

let environment = ProcessInfo.processInfo.environment
let budgetSeconds = environment["METAFUZZ_BUDGET"].flatMap(Int.init) ?? 900
let depth = environment["METAFUZZ_DEPTH"].flatMap(Int.init) ?? 2
let nodeBudget = environment["METAFUZZ_NODE_BUDGET"].flatMap(Int.init) ?? 80
let findings = URL(fileURLWithPath: environment["METAFUZZ_FINDINGS"] ?? "metafuzz-findings")

var settings: [SprawlSettings] = []
if let seed = environment["METAFUZZ_SEED"].flatMap(UInt64.init) {
    settings.append(.replay(.numeric(seed)))
}

/// The property must be a closure literal in each invocation: the macro's Void-closure handling is syntactic, and a function reference expands as if the property returned Bool.
let report: SprawlReport
if settings.isEmpty {
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
} else {
    report = #explore(
        MetaFuzz.caseGenerator(maxDepth: depth, nodeBudget: nodeBudget),
        time: .seconds(budgetSeconds),
        settings[0]
    ) { fuzzCase in
        do {
            try MetaFuzz.check(fuzzCase)
        } catch {
            MetaFuzz.recordFinding(fuzzCase, violation: error, in: findings)
            throw error
        }
    }
}

if report.clusters.isEmpty {
    print("metafuzz: no findings in \(budgetSeconds)s")
    exit(0)
}

print("metafuzz: \(report.clusters.count) finding(s) — freeze candidates in \(findings.path)")
for cluster in report.clusters {
    print("  - [\(cluster.symptoms.joined(separator: ", "))] \(cluster.reducedDescription)")
}

exit(2)
