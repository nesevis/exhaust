// MARK: - Fuzz Hot Path Probe

//
// Standalone throughput probe for the mutation-phase happy path: shipped knobs, a synthetic coverage source (no instrumentation, no SUT), a passing property, a fixed attempt count. Prints evals/s and the attempt breakdown, and runs long enough to sample under `sample` or `xctrace`. Scratch tooling for the perf pass; not registered under the Benchmark harness.

import ExhaustCore
import Foundation

/// The workloads the probe can run, each an in-package copy of an Etna generator.
enum HotPathShape {
    case ifc
    case stlc
}

/// Runs `attempts` mutation-phase attempts on `shape` under `experiments`, `repeats` times, printing evals/s each time.
func runFuzzHotPathProbe(shape: HotPathShape = .ifc, attempts: Int = 200_000, repeats: Int = 3, seed: UInt64 = 1337, experiments: FuzzExperiments = .shipped) {
    for _ in 0 ..< repeats {
        switch shape {
            case .stlc:
                probeShape(name: "STLC", generator: etnaSTLCExprGen, attempts: attempts, seed: seed, experiments: experiments)
            case .ifc:
                probeShape(name: "IFC", generator: ifcVariationGen, attempts: attempts, seed: seed, experiments: experiments)
        }
    }
}

private func probeShape<Output: Hashable>(
    name: String,
    generator: ReflectiveGenerator<Output>,
    attempts: Int,
    seed: UInt64,
    experiments: FuzzExperiments
) {
    let edgeCount = 4096
    let half = edgeCount / 2
    let runner = FuzzRunner(
        gen: generator.gen,
        property: { (_: Output) in .pass },
        source: SyntheticCoverageSource<Output>(edgeCount: edgeCount) { value in
            let hash = value.hashValue
            return [
                (edge: abs(hash) % half, hitCount: UInt8(max(1, min(255, abs(hash >> 8) % 64)))),
                (edge: half + abs(hash >> 16) % half, hitCount: 1),
            ]
        },
        configuration: FuzzRunnerConfiguration(
            budgetNanoseconds: 600_000_000_000,
            seed: seed,
            attemptLimit: attempts,
            experiments: experiments
        )
    )
    let start = DispatchTime.now().uptimeNanoseconds
    let result = runner.run()
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    let counts = result.counts
    let perSecond = Int(Double(counts.totalAttempts) / max(seconds, 0.001))
    print("[\(name)] \(perSecond) evals/s  attempts=\(counts.totalAttempts)  seconds=\(String(format: "%.2f", seconds))")
    print("  screening=\(counts.screeningAttempts) sampling=\(counts.samplingAttempts) mutation=\(counts.mutationAttempts)")
    var originLine = "  origins:"
    for origin in CandidateOrigin.allCases {
        let total = counts.attempts.count(origin: origin)
        guard total > 0 else { continue }
        let duplicates = counts.attempts.count(origin: origin, outcome: .duplicate)
        let rejected = counts.attempts.count(origin: origin, outcome: .rejectedByMaterializer)
        originLine += " \(origin)=\(total)(dup \(duplicates), rej \(rejected))"
    }
    print(originLine)
    print("  corpus=\(runner.corpus.entries.count) parents=\(runner.corpus.parentIndices.count)")
    var armLine = "  arms:"
    for arm in MutationArm.allCases {
        let draws = counts.mutationArms.draws(arm: arm)
        guard draws > 0 else { continue }
        armLine += " \(arm)=\(draws)/m\(counts.mutationArms.misses(arm: arm))/a\(counts.mutationArms.admissions(arm: arm))"
    }
    print(armLine)
    let lengths = runner.corpus.entries.map { $0.sequence.count }
    let parentLengths = runner.corpus.parentIndices.map { runner.corpus.entries[$0].sequence.count }
    let meanLength = lengths.isEmpty ? 0 : lengths.reduce(0, +) / lengths.count
    let meanParentLength = parentLengths.isEmpty ? 0 : parentLengths.reduce(0, +) / parentLengths.count
    print("  meanEntryLength=\(meanLength) meanParentLength=\(meanParentLength) entrySize=\(MemoryLayout<ChoiceSequenceValue>.size) stride=\(MemoryLayout<ChoiceSequenceValue>.stride) valueSize=\(MemoryLayout<ChoiceSequenceValue.Value>.size) choiceValueSize=\(MemoryLayout<ChoiceValue>.size)")
}
