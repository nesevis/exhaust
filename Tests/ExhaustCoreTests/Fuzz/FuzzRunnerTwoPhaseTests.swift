//
//  FuzzRunnerTwoPhaseTests.swift
//  Exhaust
//
//  Integrity checks for the two-phase mutation evaluation: phase 1 materializes with flat emission (no tree) and phase 2 rebuilds the tree only for admitted or failing candidates, so every stored tree must agree with its stored sequence and failures must still reduce from a real tree.
//

import ExhaustCore
import ExhaustTestSupport
import Foundation
import Testing

@Suite("FuzzRunner two-phase mutation evaluation")
struct FuzzRunnerTwoPhaseTests {
    @Test("Mutated admissions carry trees that flatten to their sequences")
    func mutatedAdmissionTreesMatchSequences() {
        let runner = makeRunner(property: { _ in .pass })

        let result = runner.run()

        #expect(result.counts.mutationAttempts > 0, "The run must reach mutated candidates")
        // Generation 0 entries come from sampling; generation >= 1 entries can only be admitted through the two-phase evaluateFuzzCandidate path, so their trees are phase-2 rebuilds.
        let mutatedEntries = runner.corpus.entries.filter { $0.generation >= 1 }
        #expect(mutatedEntries.isEmpty == false, "The mutation phase must admit at least one mutated child")
        for entry in runner.corpus.entries {
            #expect(
                ChoiceSequence.flatten(entry.tree) == entry.sequence,
                "corpus entry tree diverged from its sequence (generation \(entry.generation))"
            )
        }
    }

    @Test("Mutation-phase failures reduce from a real tree")
    func mutationFailuresReduceFromRealTree() {
        let runner = makeRunner(property: { values in
            values.contains { $0 > 90000 } ? .fail(.returnedFalse) : .pass
        })

        let result = runner.run()

        #expect(result.counts.mutationAttempts > 0, "The run must reach mutated candidates")
        #expect(result.clusters.isEmpty == false, "Failing candidates must produce at least one cluster")
        // A cluster reduced from a placeholder tree could not retain the failure-triggering value; a real tree reduces to a sequence that still contains one.
        let clusterWithTrigger = result.clusters.contains { cluster in
            cluster.reducedSequence.contains { entry in
                if case let .value(value) = entry {
                    return value.choice.bitPattern64 > 90
                }
                return false
            }
        }
        #expect(clusterWithTrigger, "No cluster's reduced sequence retains a failure-triggering value")
        for entry in runner.corpus.entries {
            #expect(ChoiceSequence.flatten(entry.tree) == entry.sequence)
        }
    }
}

// MARK: - Helpers

/// A runner over an array generator with value-derived synthetic coverage. Sampling seeds a diverse corpus, then plateaus (the samplable bucket space is small) and hands over to the mutation phase, where mutated children (generation >= 1) exercise the two-phase path. The boundary edges fire only on exact extreme values: uniform sampling over 0...100000 essentially never draws them, while the mutator's boundary catalog plants them readily, so mutation-only novelty is available and admissions are deterministic under the pinned seed.
private func makeRunner(
    property: @escaping @Sendable ([UInt64]) -> FuzzVerdict
) -> FuzzRunner<[UInt64]> {
    let generator = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100_000), within: 0 ... 10)
    let source = SyntheticCoverageSource<[UInt64]>(edgeCount: 128) { values in
        var edges: [(edge: Int, hitCount: UInt8)] = [(edge: values.count, hitCount: 1)]
        for (position, value) in values.prefix(8).enumerated() {
            edges.append((edge: 11 + position * 10 + Int(value % 10), hitCount: UInt8(clamping: values.count)))
        }
        let boundaryCount = values.count(where: { $0 == 0 || $0 == 100_000 })
        if boundaryCount >= 1 {
            edges.append((edge: 120, hitCount: 1))
        }
        if boundaryCount >= 2 {
            edges.append((edge: 121, hitCount: 1))
        }
        if boundaryCount >= 4 {
            edges.append((edge: 122, hitCount: 1))
        }
        return edges
    }
    return FuzzRunner(
        gen: generator,
        property: property,
        source: source,
        configuration: FuzzRunnerConfiguration(
            budgetNanoseconds: 10_000_000_000,
            seed: 1337,
            skipScreening: true,
            attemptLimit: 8000
        )
    )
}
