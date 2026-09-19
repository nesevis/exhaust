import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Shape keys and deletable sets")
struct QueryReuseParityTests {
    @Test("NodeShapeKey groups same-shaped value siblings")
    func shapeKeyGroupsValueSiblings() {
        let leaf1 = ChoiceTree.choice(ChoiceValue(1 as UInt64, tag: .uint64), .init(validRange: 0 ... 100))
        let leaf2 = ChoiceTree.choice(ChoiceValue(2 as UInt64, tag: .uint64), .init(validRange: 0 ... 100))
        let leaf3 = ChoiceTree.choice(ChoiceValue(3 as UInt64, tag: .uint64), .init(validRange: 0 ... 100))
        let tree = ChoiceTree.group([leaf1, leaf2, leaf3])
        let graph = ChoiceGraphBuilder.build(from: tree)

        var keys: [PermutationQuery.NodeShapeKey] = []
        for nodeID in graph.liveNodeIDs {
            keys.append(PermutationQuery.nodeShapeKey(graph.nodes[nodeID]))
        }
        let valueKeys = keys.filter { $0 == .value }
        #expect(valueKeys.count == 3)

        let scopes = PermutationQuery.build(graph: graph)
        #expect(scopes.count == 1)
        #expect(scopes[0].swappableGroups[0].count == 3)
    }

    @Test("NodeShapeKey separates sequences by element count and isolates empty sequences")
    func shapeKeySeparatesSequences() {
        let seq1 = ChoiceTree.sequence(
            elements: [boundedLeaf(1, in: 0 ... 100)],
            metadata: .init(validRange: nil, isRangeExplicit: false)
        )
        let seq2 = ChoiceTree.sequence(
            elements: [boundedLeaf(2, in: 0 ... 100)],
            metadata: .init(validRange: nil, isRangeExplicit: false)
        )
        let seq3 = ChoiceTree.sequence(
            elements: [boundedLeaf(3, in: 0 ... 100), boundedLeaf(4, in: 0 ... 100)],
            metadata: .init(validRange: nil, isRangeExplicit: false)
        )
        let tree = ChoiceTree.group([seq1, seq2, seq3])
        let graph = ChoiceGraphBuilder.build(from: tree)

        let scopes = PermutationQuery.build(graph: graph)
        #expect(scopes.count == 1)
        #expect(scopes[0].swappableGroups.count == 1)
        #expect(scopes[0].swappableGroups[0].count == 2)
    }

    @Test("Deletable set from RemovalQuery matches the length-constraint rule on a multi-sequence tree")
    func deletableSetMatchesRule() {
        let deletable = ChoiceTree.sequence(
            elements: [boundedLeaf(1, in: 0 ... 100), boundedLeaf(2, in: 0 ... 100), boundedLeaf(3, in: 0 ... 100)],
            metadata: .init(validRange: 1 ... 5, isRangeExplicit: true)
        )
        let atBound = ChoiceTree.sequence(
            elements: [boundedLeaf(4, in: 0 ... 100), boundedLeaf(5, in: 0 ... 100)],
            metadata: .init(validRange: 2 ... 5, isRangeExplicit: true)
        )
        let unconstrained = ChoiceTree.sequence(
            elements: [boundedLeaf(6, in: 0 ... 100)],
            metadata: .init(validRange: nil, isRangeExplicit: false)
        )
        let tree = ChoiceTree.group([deletable, atBound, unconstrained])
        let targets = MutationTargets(tree: tree)

        #expect(targets.deletableSequenceNodeIDs.count == 2)

        let graph = targets.graph
        for nodeID in targets.deletableSequenceNodeIDs {
            guard case let .sequence(metadata) = graph.nodes[nodeID].kind else {
                Issue.record("Deletable node \(nodeID) is not a sequence")
                continue
            }
            let lower = metadata.lengthConstraint?.lowerBound ?? 0
            #expect(UInt64(metadata.elementCount) > lower)
        }

        let removalScopes = RemovalQuery.elementRemovalScopes(graph: graph)
        let scopeNodeIDs = removalScopes.compactMap { $0.targets.first?.sequenceNodeID }
        #expect(targets.deletableSequenceNodeIDs == scopeNodeIDs)
    }

    @Test("Repertoire sights a superset of the per-parent structural arms")
    func repertoireIsSuperset() {
        let leaf1 = boundedLeaf(100, in: 0 ... 200)
        let leaf2 = boundedLeaf(150, in: 0 ... 200)
        let leaf3 = boundedLeaf(175, in: 0 ... 200)
        let zipBranch = ChoiceTree.group([leaf1, leaf2, leaf3])
        let scalarBranch = boundedLeaf(0, in: 0 ... 0)
        let tree = ChoiceTree.group([
            .branch(fingerprint: 1, weight: 1, id: 0, branchCount: 2, choice: scalarBranch, isSelected: true),
            .branch(fingerprint: 1, weight: 1, id: 1, branchCount: 2, choice: zipBranch),
        ])
        let fullGraph = ChoiceGraphBuilder.build(from: tree)
        let sighted = MutationArmRepertoire.sighted(in: fullGraph)

        let targets = MutationTargets(tree: tree)
        for arm in MutationArm.allCases where targets.structuralArms.contains(arm) {
            #expect(sighted.contains(arm), "Repertoire missing arm \(arm) that targets reports")
        }
    }

    @Test("Seeded fuzz run produces deterministic arm counts across two identical runs")
    func seededRunDeterminism() {
        func run() -> FuzzRunCounts {
            var experiments = FuzzExperiments()
            experiments.graphMutation = true
            experiments.pairMutation = true
            let runner = FuzzRunner(
                gen: Gen.zip(
                    Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
                    Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
                    Gen.choose(in: 0 ... 1000 as ClosedRange<Int>)
                ),
                property: { value in
                    value.0 + value.1 + value.2 > 2800 ? .fail(.returnedFalse) : .pass
                },
                source: SyntheticCoverageSource<(Int, Int, Int)>(edgeCount: 32, edges: { value in
                    [value.0 & 0b111, 8 + (value.1 & 0b111), 16 + (value.2 & 0b111)]
                }),
                configuration: FuzzRunnerConfiguration(
                    budgetNanoseconds: 60_000_000_000,
                    seed: 1337,
                    attemptLimit: 5000,
                    experiments: experiments
                )
            )
            return runner.run().counts
        }
        let first = run()
        let second = run()
        for arm in MutationArm.allCases {
            #expect(first.mutationArms.draws(arm: arm) == second.mutationArms.draws(arm: arm))
            #expect(first.mutationArms.misses(arm: arm) == second.mutationArms.misses(arm: arm))
            #expect(first.mutationArms.admissions(arm: arm) == second.mutationArms.admissions(arm: arm))
        }
        #expect(first.totalAttempts == second.totalAttempts)
    }
}
