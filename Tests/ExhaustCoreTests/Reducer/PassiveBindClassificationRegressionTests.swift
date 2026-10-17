import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Passive bind classification consistency")
struct PassiveBindClassificationRegressionTests {
    @Test("A sequence length change defers to classification instead of proving divergence")
    func lengthChangeIsInconclusive() {
        let oldTree = Self.tree(controller: 4, count: 12)
        let newTree = Self.tree(controller: 3, count: 9)
        var old = ChoiceGraph.build(from: oldTree)
        old.observeBindTopologies(tree: oldTree)
        var fresh = ChoiceGraph.build(from: newTree)
        fresh.bindTopologyObservations = old.bindTopologyObservations
        fresh.observeBindTopologies(tree: newTree)

        #expect(ChoiceGraph.sameTopology(oldTree, newTree))
        #expect(ChoiceGraph.subtreeFingerprint(oldTree) != ChoiceGraph.subtreeFingerprint(newTree))
        #expect(fresh.bindClassifications[17] == nil)
        #expect(fresh.bindTopologyObservations[17] != nil)
    }

    @Test("Unchanged fingerprints retain the passive identical-shape shortcut")
    func unchangedFingerprintClassifies() {
        let oldTree = Self.tree(controller: 4, count: 12)
        let newTree = Self.tree(controller: 3, count: 12)
        var old = ChoiceGraph.build(from: oldTree)
        old.observeBindTopologies(tree: oldTree)
        var fresh = ChoiceGraph.build(from: newTree)
        fresh.bindTopologyObservations = old.bindTopologyObservations
        fresh.observeBindTopologies(tree: newTree)

        #expect(fresh.bindClassifications[17]?.topology == .identical)
        #expect(fresh.bindClassifications[17]?.liftability == .both)
        #expect(fresh.bindTopologyObservations[17] == nil)
    }

    private static func tree(controller: UInt64, count: Int) -> ChoiceTree {
        .bind(
            fingerprint: 17,
            inner: .uint64(controller, in: 1 ... 10),
            bound: .bind(
                fingerprint: 18,
                inner: .uint64(3, in: 1 ... 10),
                bound: .sequence(
                    elements: Array(repeating: .uint64(1, in: 0 ... 1), count: count),
                    metadata: .init(validRange: UInt64(count) ... UInt64(count), isRangeExplicit: true)
                )
            )
        )
    }
}
