import Testing
@testable import ExhaustCore

@Suite("Universal sequence patches")
struct SequencePatchTests {
    @Test("Empty, inline, and multiple edits match full hashing and restore every entry", arguments: [0, 1, 2, 4, 8])
    func hashAndRestore(editCount: Int) {
        let baseline = ChoiceSequence((0 ..< 16).map { value in
            ChoiceSequenceValue.value(.init(
                choice: ChoiceValue(UInt64(value), tag: .uint64),
                validRange: 0 ... 100,
                isRangeExplicit: true
            ))
        })
        var patch = SequencePatch()
        var expected = baseline
        for index in 0 ..< editCount {
            let position = index * 2
            let replacement: ChoiceSequenceValue = index.isMultiple(of: 2)
                ? .just
                : .value(.init(choice: ChoiceValue(UInt64(99), tag: .uint64), validRange: nil))
            let edit = SequencePatch.Edit(position: position, replacement: replacement)
            switch index {
                case 0:
                    patch = SequencePatch(edit)
                default:
                    patch.append(edit)
            }
            expected[position] = replacement
        }

        #expect(patch.count == editCount)
        #expect(Array(patch.reversed().map(\.position)) == (0 ..< editCount).reversed().map { $0 * 2 })
        #expect(
            patch.hash(baseHash: ZobristHash.hash(of: baseline), baseSequence: baseline)
                == ZobristHash.hash(of: expected)
        )
        var buffer = baseline
        for _ in 0 ..< 3 {
            patch.write(into: &buffer)
            #expect(buffer == expected)
            patch.restore(into: &buffer, baseSequence: baseline)
            #expect(buffer == baseline)
        }
    }

    @Test(
        "Mixed eager and lazy probes preserve observations, cache outcomes, and acceptance",
        arguments: [false, true], [false, true]
    )
    func interchangeableRepresentations(shouldPass: Bool, hasObserver: Bool) throws {
        let generator = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), exactly: 2)
        let values: [UInt64] = [50, 60]
        let tree = try #require(try Interpreters.reflect(generator, with: values))
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence(tree)
        let positions = try graph.leafNodes.map { try #require(graph.nodes[$0].positionRange).lowerBound }

        // Repeated rejected probes exercise the cache; accepted probes require rebasing before the next patch.
        let replacements: [[(Int, UInt64)]] = [[(0, 30)], [(1, 40)], [(1, 40)], [(0, 20), (1, 20)], [], [(0, 10)]]

        /// The fourth probe is always eager to exercise the transition through a fully rewritten buffer.
        func run(usesLazyCandidates: Bool) -> Snapshot {
            let recorder = ProbeTraceRecorder()
            var context = Reducer.Context(
                incumbent: Counterexample(sequence: sequence, tree: tree, output: values),
                incumbentHash: ZobristHash.hash(of: sequence),
                graph: graph,
                rejectCache: [],
                decoder: ReductionDecoder(
                    generator: generator.erase(),
                    property: { _ in shouldPass },
                    probeWrapper: nil,
                    hasBind: false
                ),
                encoder: ValueSearchEncoder.self,
                observer: hasObserver ? recorder.record : nil
            )
            for (index, replacements) in replacements.enumerated() {
                let baseline = context.incumbent.sequence
                var patch = SequencePatch()
                var changes: [LeafChange] = []
                for (leafIndex, pattern) in replacements {
                    let position = positions[leafIndex]
                    let entry = baseline[position].withBitPattern(pattern)
                    patch.append(.init(position: position, replacement: entry))
                    guard entry != baseline[position] else {
                        continue
                    }
                    changes.append(LeafChange(
                        leafNodeID: graph.leafNodes[leafIndex],
                        newValue: ChoiceValue(pattern, tag: .uint64),
                        mayReshape: false
                    ))
                }
                let candidate: ReductionCandidate
                switch usesLazyCandidates && index != 3 {
                    case true:
                        candidate = .lazy(
                            patch,
                            mutation: .leafValues(changes),
                            admission: .standard
                        )
                    case false:
                        context.candidateBuffer = baseline
                        patch.write(into: &context.candidateBuffer)
                        candidate = .eager(mutation: .leafValues(changes), admission: .standard)
                }
                _ = Reducer.evaluateAndCommit(candidate, configuration: .standard, context: &context)
            }
            return Snapshot(
                report: context.report,
                incumbent: context.incumbent,
                baseHash: context.baseHash,
                events: recorder.events
            )
        }

        let eager = run(usesLazyCandidates: false)
        let mixed = run(usesLazyCandidates: true)
        #expect(mixed.events == eager.events)
        #expect(mixed.report.counts == eager.report.counts)
        #expect(mixed.incumbent.sequence == eager.incumbent.sequence)
        #expect(mixed.baseHash == eager.baseHash)
        #expect(mixed.report.acceptedLeafNodeIDs == eager.report.acceptedLeafNodeIDs)
    }

    private struct Snapshot {
        let report: ReductionPassReport
        let incumbent: Counterexample
        let baseHash: UInt64
        let events: [ProbeTraceRecorder.Event]
    }
}
