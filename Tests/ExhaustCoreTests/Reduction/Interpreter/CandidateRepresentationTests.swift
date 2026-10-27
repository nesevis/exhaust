import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Eager and lazy candidate equivalence")
struct CandidateRepresentationTests {
    @Test(
        "Generated replacement streams preserve observations, cache outcomes, and acceptance across representations",
        arguments: [false, true], [false, true]
    )
    func interchangeableRepresentations(shouldPass: Bool, hasObserver: Bool) throws {
        let generator = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 8), exactly: 2)
        let values: [UInt64] = [4, 6]
        let tree = try #require(try Interpreters.reflect(generator, with: values))
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence(tree)
        let positions = try graph.leafNodes.map { try #require(graph.nodes[$0].positionRange).lowerBound }

        func run(_ steps: [Step], forcesEager: Bool) -> Snapshot {
            let recorder = ProbeTraceRecorder()
            var context = Reducer.Context(
                incumbent: Counterexample(sequence: sequence, tree: tree, output: values),
                incumbentHash: ZobristHash.hash(of: sequence),
                graph: graph,
                rejectCache: ProbeCache(),
                decoder: ReductionDecoder(
                    generator: generator.erase(),
                    property: { _ in shouldPass },
                    probeWrapper: nil,
                    hasBind: false
                ),
                encoder: ValueSearchEncoder.self,
                observer: hasObserver ? recorder.record : nil
            )
            for step in steps {
                for _ in 0 ..< step.repetitions {
                    let baseline = context.incumbent.sequence
                    var patch = SequencePatch()
                    var changes: [LeafChange] = []
                    for replacement in step.replacements {
                        let position = positions[replacement.leafIndex]
                        let entry = baseline[position].withBitPattern(replacement.value)
                        patch.append(.init(position: position, replacement: entry))
                        guard entry != baseline[position] else {
                            continue
                        }
                        changes.append(LeafChange(
                            leafNodeID: graph.leafNodes[replacement.leafIndex],
                            newValue: ChoiceValue(replacement.value, tag: .uint64),
                            mayReshape: false
                        ))
                    }
                    let representation = forcesEager ? .eager : step.representation
                    let candidate: ReductionCandidate
                    switch representation {
                        case .lazy:
                            candidate = .lazy(patch, mutation: .leafValues(changes), admission: .standard)
                        case .eager:
                            // The reference writes replacements directly so it does not share the patch's write path.
                            context.candidateBuffer = baseline
                            for replacement in step.replacements {
                                let position = positions[replacement.leafIndex]
                                context.candidateBuffer[position] = baseline[position].withBitPattern(replacement.value)
                            }
                            candidate = .eager(mutation: .leafValues(changes), admission: .standard)
                    }
                    _ = Reducer.evaluateAndCommit(candidate, configuration: .standard, context: &context)
                }
            }
            return Snapshot(
                counts: context.report.counts,
                sequence: context.incumbent.sequence,
                baseHash: context.baseHash,
                acceptedLeafNodeIDs: context.report.acceptedLeafNodeIDs,
                events: recorder.events
            )
        }

        var sawEmptyPatch = false
        var sawMultipleEdits = false
        var sawEagerToLazy = false
        var sawLazyToEager = false
        var cacheRejections = 0
        var acceptances = 0
        try exhaustCheck(Self.steps, maxIterations: 300) { steps in
            let eager = run(steps, forcesEager: true)
            let mixed = run(steps, forcesEager: false)
            sawEmptyPatch = sawEmptyPatch || steps.contains { $0.replacements.isEmpty }
            sawMultipleEdits = sawMultipleEdits || steps.contains { $0.replacements.count > 1 }
            for (first, second) in zip(steps, steps.dropFirst()) {
                sawEagerToLazy = sawEagerToLazy || (first.representation == .eager && second.representation == .lazy)
                sawLazyToEager = sawLazyToEager || (first.representation == .lazy && second.representation == .eager)
            }
            cacheRejections += mixed.counts.rejectedByCache
            acceptances += mixed.counts.accepted
            return mixed == eager
        }
        #expect(sawEmptyPatch)
        #expect(sawMultipleEdits)
        #expect(sawEagerToLazy)
        #expect(sawLazyToEager)
        #expect(cacheRejections > 0)
        switch shouldPass {
            case true:
                #expect(acceptances == 0)
            case false:
                #expect(acceptances > 0)
        }
    }

    private enum Representation {
        case eager, lazy
    }

    private struct Replacement {
        let leafIndex: Int
        let value: UInt64
    }

    private struct Step {
        let replacements: [Replacement]
        let representation: Representation
        let repetitions: UInt64
    }

    private static let steps: Generator<[Step]> = {
        let replacements = Gen.zip(
            Gen.choose(in: UInt64(0) ... 3, scaling: .constant),
            Gen.arrayOf(Gen.choose(in: UInt64(0) ... 8, scaling: .constant), exactly: 2)
        ).map { mask, values in
            values.enumerated().compactMap { index, value -> Replacement? in
                guard mask & (1 << index) != 0 else {
                    return nil
                }
                return Replacement(leafIndex: index, value: value)
            }
        }
        let representation = Gen.pick(choices: [
            (weight: UInt64(1), generator: Gen.just(Representation.eager)),
            (weight: UInt64(1), generator: Gen.just(Representation.lazy)),
        ])
        let step = Gen.zip(replacements, representation, Gen.choose(in: UInt64(1) ... 3, scaling: .constant))
            .map { Step(replacements: $0.0, representation: $0.1, repetitions: $0.2) }
        return Gen.arrayOf(step, within: 0 ... 20, scaling: .constant)
    }()

    private struct Snapshot: Equatable {
        let counts: ReductionProbeCounts
        let sequence: ChoiceSequence
        let baseHash: UInt64
        let acceptedLeafNodeIDs: Set<Int>
        let events: [ProbeTraceRecorder.Event]
    }
}
