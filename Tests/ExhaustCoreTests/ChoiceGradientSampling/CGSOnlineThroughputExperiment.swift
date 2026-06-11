//
//  CGSOnlineThroughputExperiment.swift
//  ExhaustTests
//
//  Manual benchmark harness behind the CGS tuning postmortem (ExhaustDocs/cgs-tuning-postmortem-2026-06-11.md).
//
//  Measures time-to-milestone for unique valid values under three strategies: plain rejection, OnlineCGSInterpreter run directly as a generator (the paper's fully online mode), and the production pipeline (ChoiceGradientTuner warmup → baked weights → cheap nextValueOnly walk).
//
//  Reference points from Goldstein, "Property-Based Testing for the People" (Table 3.2, 60s on an M1): BST rejection 7,354 unique, BST online CGS 22,107 unique, AVL rejection 129, AVL online CGS 219.
//

import ExhaustCore
import ExhaustTestSupport
import Foundation
import Testing

@Suite("CGS Online Throughput Experiment", .serialized, .disabled("Manual benchmark — run with --filter"))
struct CGSOnlineThroughputExperiment {
    @Test("Side-by-side gap fill: tuned pipeline on paper fixture, fully online AVL")
    func sideBySideGapFill() throws {
        let uniform = Self.uniformBST(maxDepth: 5)
        let paperPredicate: (BST) -> Bool = { $0.isValidBST() }
        try runTunedPipeline(uniform, predicate: paperPredicate, label: "BST uniform/paper predicate: Tune + walk")

        let avlGenerator = BST.arbitrary()
        let avlPredicate: (BST) -> Bool = { $0.height >= 1 && $0.isValidAVL() }
        try runOnlineCGS(avlGenerator, predicate: avlPredicate, sampleCount: 10, label: "AVL: fully online N=10 (shipped interpreter)")
    }

    private static let milestones = [100, 200, 500, 1000, 2000, 5000, 10000, 20000]
    private static let wallClockCap: Duration = .seconds(60)

    @Test("Uniform BST (paper fixture): rejection vs online CGS, time to milestones")
    func uniformBSTMilestones() throws {
        let generator = Self.uniformBST(maxDepth: 5)
        // The paper's exact validity condition: a leaf is a valid BST. No height floor.
        let predicate: (BST) -> Bool = { $0.isValidBST() }

        try runRejection(generator, predicate: predicate, label: "Rejection (uniform)")
        try runOnlineCGS(generator, predicate: predicate, sampleCount: 10, label: "OnlineCGS N=10 (uniform)")
        try runOnlineCGS(generator, predicate: predicate, sampleCount: 50, label: "OnlineCGS N=50 (uniform)")
    }

    @Test("Tuned pipeline (BST): warmup, then cheap walk")
    func tunedPipelineMilestones() throws {
        let generator = BST.arbitrary()
        let predicate: (BST) -> Bool = { $0.height >= 1 && $0.isValidBST() }

        try runRejection(generator, predicate: predicate, label: "Rejection")
        try runTunedPipeline(generator, predicate: predicate, label: "Tune + walk")
    }

    @Test("Tuned pipeline (AVL): warmup, then cheap walk")
    func avlTunedPipelineMilestones() throws {
        let generator = BST.arbitrary()
        let predicate: (BST) -> Bool = { $0.height >= 1 && $0.isValidAVL() }

        try runRejection(generator, predicate: predicate, label: "AVL Rejection")
        try runTunedPipeline(generator, predicate: predicate, label: "AVL Tune + walk")
    }

    /// The paper's BST generator: follows the type definition with uniform choice weights (leaf 1 : node 1), depth 5, values 0...9.
    private static func uniformBST(maxDepth: Int) -> Generator<BST> {
        if maxDepth <= 0 {
            return Gen.just(.leaf)
        }
        let nodeBranch = Gen.zip(
            uniformBST(maxDepth: maxDepth - 1),
            Gen.choose(in: 0 ... 9 as ClosedRange<UInt>),
            uniformBST(maxDepth: maxDepth - 1)
        ).map { left, value, right in
            BST.node(left: left, value: value, right: right)
        }
        return Gen.pick(choices: [(1, Gen.just(.leaf)), (1, nodeBranch)])
    }

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
        let start = ContinuousClock.now
        print("=== \(label) ===")
        while nextMilestone < Self.milestones.count, ContinuousClock.now - start < Self.wallClockCap {
            guard let value = try iterator.next() else { break }
            total += 1
            if predicate(value), unique.insert(value).inserted {
                if unique.count >= Self.milestones[nextMilestone] {
                    report(milestone: Self.milestones[nextMilestone], total: total, start: start)
                    nextMilestone += 1
                }
            }
        }
        finish(unique: unique.count, total: total, start: start)
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
        let start = ContinuousClock.now
        print("=== \(label) ===")
        while nextMilestone < Self.milestones.count, ContinuousClock.now - start < Self.wallClockCap {
            guard let value = try iterator.next() else { break }
            total += 1
            if predicate(value), unique.insert(value).inserted {
                if unique.count >= Self.milestones[nextMilestone] {
                    report(milestone: Self.milestones[nextMilestone], total: total, start: start)
                    nextMilestone += 1
                }
            }
        }
        finish(unique: unique.count, total: total, start: start)
    }

    private func runTunedPipeline(
        _ generator: Generator<BST>,
        predicate: @escaping (BST) -> Bool,
        label: String
    ) throws {
        var unique = Set<BST>()
        var total = 0
        var nextMilestone = 0
        let start = ContinuousClock.now
        print("=== \(label) ===")

        let tuned: Generator<BST> = try ChoiceGradientTuner<BST>.tune(
            generator,
            predicate: predicate,
            warmupRuns: 400,
            sampleCount: 10,
            seed: 12345,
            weightingStrategy: .fitnessSharing
        )
        let tuneElapsed = ContinuousClock.now - start
        print("  tune: \(format(tuneElapsed))")

        var iterator = ValueAndChoiceTreeInterpreter(tuned, seed: 42, maxRuns: .max)
        while nextMilestone < Self.milestones.count, ContinuousClock.now - start < Self.wallClockCap {
            guard let value = try iterator.nextValueOnly() else { break }
            total += 1
            if predicate(value), unique.insert(value).inserted {
                if unique.count >= Self.milestones[nextMilestone] {
                    report(milestone: Self.milestones[nextMilestone], total: total, start: start)
                    nextMilestone += 1
                }
            }
        }
        finish(unique: unique.count, total: total, start: start)
    }

    // MARK: - Reporting

    private func report(milestone: Int, total: Int, start: ContinuousClock.Instant) {
        let elapsed = ContinuousClock.now - start
        print("  \(milestone) unique @ \(format(elapsed))  (\(total) runs)")
    }

    private func finish(unique: Int, total: Int, start: ContinuousClock.Instant) {
        let elapsed = ContinuousClock.now - start
        let perSecond = Double(unique) / max(0.001, seconds(elapsed))
        print("  final: \(unique) unique / \(total) runs in \(format(elapsed))  (\(String(format: "%.0f", perSecond)) unique/s)")
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func format(_ duration: Duration) -> String {
        String(format: "%.2fs", seconds(duration))
    }
}
