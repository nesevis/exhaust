// MARK: - Mutation Arm Gate Cost Benchmarks

//
// Times the admissibility gate mechanism on frozen corpora, comparing control
// (no gate) against admissibility (repertoire-gated draws). Both arms share
// one corpus so parent shapes, learned weights, and corpus size are identical.

import Benchmark
import Exhaust
import ExhaustCore
import ExhaustMetaFuzz
import Foundation

// MARK: - Configuration

private let drawsPerIteration = 10000

// MARK: - Registration

func registerMutationArmGateBenchmarks() {
    registerShapeBenchmarks(
        name: "STLC",
        generator: etnaSTLCExprGen,
        edgeCount: 4096,
        hitEdges: hashBasedEdges(edgeCount: 4096)
    )

    registerShapeBenchmarks(
        name: "MetaFuzz",
        generator: MetaFuzz.caseGenerator(maxDepth: 2, nodeBudget: 80),
        edgeCount: 4096,
        hitEdges: { (value: MetaFuzzCase) in
            let combined = value.valueSeed &+ value.perturbationSeed
            let edge1 = Int(combined % 2048)
            let edge2 = 2048 + Int((combined >> 16) % 2048)
            let hitCount = UInt8(max(1, min(255, (combined >> 32) % 64)))
            return [(edge: edge1, hitCount: hitCount), (edge: edge2, hitCount: 1)]
        }
    )

    registerShapeBenchmarks(
        name: "IFC",
        generator: ifcVariationGen,
        edgeCount: 4096,
        hitEdges: hashBasedEdges(edgeCount: 4096)
    )
}

// MARK: - Per-Shape Registration

private func registerShapeBenchmarks<Output>(
    name: String,
    generator: ReflectiveGenerator<Output>,
    edgeCount: Int,
    hitEdges: @escaping @Sendable (Output) -> [(edge: Int, hitCount: UInt8)]
) {
    let sharedRunner = buildFrozenCorpus(
        generator: generator,
        edgeCount: edgeCount,
        seed: 1337,
        armAdmissibility: true,
        hitEdges: hitEdges
    )

    let parents = sharedRunner.corpus.parentIndices

    benchmark("Gate \(name): nextCandidate") {
        sharedRunner.prng = Xoshiro256(seed: 42_424_242)
        for iteration in 0 ..< drawsPerIteration {
            let parentIndex = parents[iteration % parents.count]
            let parent = sharedRunner.corpus.entries[parentIndex]
            let draw = sharedRunner.nextCandidate(from: parent, parentIndex: parentIndex)
            benchmarkSink = UInt64(draw.candidate.count)
        }
    }

    benchmark("Gate \(name): drawArm selection") {
        sharedRunner.prng = Xoshiro256(seed: 99)
        for _ in 0 ..< drawsPerIteration {
            let arm = sharedRunner.drawArm(eligible: .all)
            benchmarkSink = UInt64(arm.rawValue)
        }
    }

    benchmark("Gate \(name): drawArm gated") {
        sharedRunner.prng = Xoshiro256(seed: 99)
        let eligible = sharedRunner.sightedArms ?? .all
        for _ in 0 ..< drawsPerIteration {
            let arm = sharedRunner.drawArm(eligible: eligible)
            benchmarkSink = UInt64(arm.rawValue)
        }
    }

    benchmark("Gate \(name): sightedArms lookup") {
        for _ in 0 ..< drawsPerIteration {
            benchmarkSink = UInt64(sharedRunner.sightedArms?.rawValue ?? 0)
        }
    }

    benchmark("Gate \(name): eligibility check") {
        sharedRunner.prng = Xoshiro256(seed: 42_424_242)
        for iteration in 0 ..< drawsPerIteration {
            let parentIndex = parents[iteration % parents.count]
            let parent = sharedRunner.corpus.entries[parentIndex]
            let eligible = sharedRunner.eligibleSet(for: parent, parentIndex: parentIndex)
            benchmarkSink = UInt64(eligible.rawValue)
        }
    }
}

// MARK: - Corpus Construction

private func buildFrozenCorpus<Output>(
    generator: ReflectiveGenerator<Output>,
    edgeCount: Int,
    seed: UInt64,
    armAdmissibility: Bool,
    hitEdges: @escaping @Sendable (Output) -> [(edge: Int, hitCount: UInt8)]
) -> FuzzRunner<Output> {
    var experiments = FuzzExperiments()
    experiments.graphMutation = true
    experiments.pairMutation = true
    experiments.armAdmissibility = armAdmissibility
    experiments.armEligibility = true
    let runner = FuzzRunner(
        gen: generator.gen,
        property: { (_: Output) in .pass },
        source: SyntheticCoverageSource<Output>(edgeCount: edgeCount, hitEdges: hitEdges),
        configuration: FuzzRunnerConfiguration(
            budgetNanoseconds: 600_000_000_000,
            seed: seed,
            attemptLimit: 200_000,
            experiments: experiments
        )
    )
    _ = runner.run()
    return runner
}

// MARK: - Helpers

private func hashBasedEdges<Value: Hashable>(edgeCount: Int) -> @Sendable (Value) -> [(edge: Int, hitCount: UInt8)] {
    let half = edgeCount / 2
    return { value in
        let hash = value.hashValue
        return [
            (edge: abs(hash) % half, hitCount: UInt8(max(1, min(255, abs(hash >> 8) % 64)))),
            (edge: half + abs(hash >> 16) % half, hitCount: 1),
        ]
    }
}

/// Written to from benchmark loops to prevent dead-code elimination.
nonisolated(unsafe) var benchmarkSink: UInt64 = 0
