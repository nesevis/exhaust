// MARK: - CGS Online Throughput Experiment

//
// Manual benchmark harness behind the CGS tuning postmortem (ExhaustDocs/cgs-tuning-postmortem-2026-06-11.md).
//
// Measures time-to-milestone for unique valid values under three strategies: plain rejection, OnlineCGSInterpreter run directly as a generator (the paper's fully online mode), and the production pipeline (ChoiceGradientTuner warmup → baked weights → cheap nextValueOnly walk).
//
// Reference points from Goldstein, "Property-Based Testing for the People" (Table 3.2, 60s on an M1): BST rejection 7,354 unique, BST online CGS 22,107 unique, AVL rejection 129, AVL online CGS 219.
//
// Ported from Tests/ExhaustCoreTests/ChoiceGradientSampling/CGSOnlineThroughputExperiment.swift (2026-07-04).

import Benchmark
import ExhaustCore
import Foundation

func registerCGSOnlineThroughputBenchmarks() {
    benchmark("CGS online throughput: side-by-side gap fill") {
        do {
            let uniform = BenchmarkBST.uniform(maxDepth: 5)
            let paperPredicate: (BenchmarkBST) -> Bool = { $0.isValidBST() }
            try runTunedPipeline(uniform, predicate: paperPredicate, label: "BST uniform/paper predicate: Tune + walk")

            let avlGenerator = BenchmarkBST.arbitrary()
            let avlPredicate: (BenchmarkBST) -> Bool = { $0.height >= 1 && $0.isValidAVL() }
            try runOnlineCGS(avlGenerator, predicate: avlPredicate, sampleCount: 10, label: "AVL: fully online N=10 (shipped interpreter)")
        } catch {
            print("CGS gap-fill benchmark failed: \(error)")
        }
    }

    benchmark("CGS online throughput: uniform BST (paper fixture) milestones") {
        do {
            let generator = BenchmarkBST.uniform(maxDepth: 5)
            // The paper's exact validity condition: a leaf is a valid BST. No height floor.
            let predicate: (BenchmarkBST) -> Bool = { $0.isValidBST() }

            try runRejection(generator, predicate: predicate, label: "Rejection (uniform)")
            try runOnlineCGS(generator, predicate: predicate, sampleCount: 10, label: "OnlineCGS N=10 (uniform)")
            try runOnlineCGS(generator, predicate: predicate, sampleCount: 50, label: "OnlineCGS N=50 (uniform)")
        } catch {
            print("CGS uniform-BST benchmark failed: \(error)")
        }
    }

    benchmark("CGS online throughput: tuned pipeline (BST) milestones") {
        do {
            let generator = BenchmarkBST.arbitrary()
            let predicate: (BenchmarkBST) -> Bool = { $0.height >= 1 && $0.isValidBST() }

            try runRejection(generator, predicate: predicate, label: "Rejection")
            try runTunedPipeline(generator, predicate: predicate, label: "Tune + walk")
        } catch {
            print("CGS tuned-pipeline BST benchmark failed: \(error)")
        }
    }

    benchmark("CGS online throughput: tuned pipeline (AVL) milestones") {
        do {
            let generator = BenchmarkBST.arbitrary()
            let predicate: (BenchmarkBST) -> Bool = { $0.height >= 1 && $0.isValidAVL() }

            try runRejection(generator, predicate: predicate, label: "AVL Rejection")
            try runTunedPipeline(generator, predicate: predicate, label: "AVL Tune + walk")
        } catch {
            print("CGS tuned-pipeline AVL benchmark failed: \(error)")
        }
    }
}

// MARK: - Configuration

private let milestones = [100, 200, 500, 1000, 2000, 5000, 10000, 20000]
private let wallClockCapSeconds: Double = 60

// MARK: - Runners

private func runRejection<Value: Hashable>(
    _ generator: Generator<Value>,
    predicate: (Value) -> Bool,
    label: String
) throws {
    var iterator = ValueInterpreter(generator, seed: 42, maxRuns: .max)
    var unique = Set<Value>()
    var total = 0
    var nextMilestone = 0
    let timer = BenchmarkTimer()
    print("=== \(label) ===")
    while nextMilestone < milestones.count, timer.elapsedSeconds < wallClockCapSeconds {
        guard let value = try iterator.next() else { break }
        total += 1
        if predicate(value), unique.insert(value).inserted {
            if unique.count >= milestones[nextMilestone] {
                report(milestone: milestones[nextMilestone], total: total, timer: timer)
                nextMilestone += 1
            }
        }
    }
    finish(unique: unique.count, total: total, timer: timer)
}

private func runOnlineCGS<Value: Hashable>(
    _ generator: Generator<Value>,
    predicate: @escaping (Value) -> Bool,
    sampleCount: UInt64,
    label: String
) throws {
    var iterator = OnlineCGSInterpreter(
        generator,
        predicate: predicate,
        sampleCount: sampleCount,
        seed: 42,
        maxRuns: .max,
        fitnessAccumulator: FitnessAccumulator()
    )
    var unique = Set<Value>()
    var total = 0
    var nextMilestone = 0
    let timer = BenchmarkTimer()
    print("=== \(label) ===")
    while nextMilestone < milestones.count, timer.elapsedSeconds < wallClockCapSeconds {
        guard let value = try iterator.next() else { break }
        total += 1
        if predicate(value), unique.insert(value).inserted {
            if unique.count >= milestones[nextMilestone] {
                report(milestone: milestones[nextMilestone], total: total, timer: timer)
                nextMilestone += 1
            }
        }
    }
    finish(unique: unique.count, total: total, timer: timer)
}

private func runTunedPipeline(
    _ generator: Generator<BenchmarkBST>,
    predicate: @escaping (BenchmarkBST) -> Bool,
    label: String
) throws {
    var unique = Set<BenchmarkBST>()
    var total = 0
    var nextMilestone = 0
    let timer = BenchmarkTimer()
    print("=== \(label) ===")

    let tuned: Generator<BenchmarkBST> = try ChoiceGradientTuner<BenchmarkBST>.tune(
        generator,
        predicate: predicate,
        warmupRuns: 400,
        sampleCount: 10,
        seed: 12345,
        weightingStrategy: .fitnessSharing
    )
    print("  tune: \(format(timer.elapsedSeconds))")

    var iterator = ValueAndChoiceTreeInterpreter(tuned, seed: 42, maxRuns: .max)
    while nextMilestone < milestones.count, timer.elapsedSeconds < wallClockCapSeconds {
        guard let value = try iterator.nextValueOnly() else { break }
        total += 1
        if predicate(value), unique.insert(value).inserted {
            if unique.count >= milestones[nextMilestone] {
                report(milestone: milestones[nextMilestone], total: total, timer: timer)
                nextMilestone += 1
            }
        }
    }
    finish(unique: unique.count, total: total, timer: timer)
}

// MARK: - Reporting

private func report(milestone: Int, total: Int, timer: BenchmarkTimer) {
    print("  \(milestone) unique @ \(format(timer.elapsedSeconds))  (\(total) runs)")
}

private func finish(unique: Int, total: Int, timer: BenchmarkTimer) {
    let elapsedSeconds = timer.elapsedSeconds
    let perSecond = Double(unique) / max(0.001, elapsedSeconds)
    print("  final: \(unique) unique / \(total) runs in \(format(elapsedSeconds))  (\(String(format: "%.0f", perSecond)) unique/s)")
}

private func format(_ seconds: Double) -> String {
    String(format: "%.2fs", seconds)
}
