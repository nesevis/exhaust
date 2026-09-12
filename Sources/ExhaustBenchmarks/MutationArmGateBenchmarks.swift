// MARK: - Mutation Arm Gate Cost Benchmarks

//
// Times the admissibility gate mechanism in nanoseconds per draw on frozen corpora,
// comparing control (no gate) against admissibility (repertoire-gated draws).

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
    let controlRunner = buildFrozenCorpus(
        generator: generator,
        edgeCount: edgeCount,
        seed: 1337,
        armAdmissibility: false,
        hitEdges: hitEdges
    )
    let admissibilityRunner = buildFrozenCorpus(
        generator: generator,
        edgeCount: edgeCount,
        seed: 1337,
        armAdmissibility: true,
        hitEdges: hitEdges
    )

    let controlParents = controlRunner.corpus.parentIndices
    let admParents = admissibilityRunner.corpus.parentIndices

    benchmark("Gate \(name): control nextCandidate") {
        controlRunner.prng = Xoshiro256(seed: 42_424_242)
        for iteration in 0 ..< drawsPerIteration {
            let parentIndex = controlParents[iteration % controlParents.count]
            let parent = controlRunner.corpus.entries[parentIndex]
            _ = controlRunner.nextCandidate(from: parent, parentIndex: parentIndex)
        }
    }

    benchmark("Gate \(name): admissibility nextCandidate") {
        admissibilityRunner.prng = Xoshiro256(seed: 42_424_242)
        for iteration in 0 ..< drawsPerIteration {
            let parentIndex = admParents[iteration % admParents.count]
            let parent = admissibilityRunner.corpus.entries[parentIndex]
            _ = admissibilityRunner.nextCandidate(from: parent, parentIndex: parentIndex)
        }
    }

    benchmark("Gate \(name): drawArm ungated") {
        controlRunner.prng = Xoshiro256(seed: 99)
        for _ in 0 ..< drawsPerIteration {
            _ = controlRunner.drawArm(eligible: .all)
        }
    }

    benchmark("Gate \(name): sightedArms lookup") {
        for _ in 0 ..< drawsPerIteration {
            let sighted = admissibilityRunner.sightedArms
            if let sighted {
                blackhole(sighted.rawValue)
            }
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

@inline(never)
private func blackhole(_ value: some Any) {
    withExtendedLifetime(value) {}
}
