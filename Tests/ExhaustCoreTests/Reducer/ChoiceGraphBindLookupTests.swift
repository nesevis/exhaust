import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Choice graph bind lookup")
struct ChoiceGraphBindLookupTests {
    @Test("Repeated bind fingerprints are distinguished by their paths")
    func repeatedFingerprintsUsePaths() throws {
        let graph = ChoiceGraph.build(from: .bind(
            fingerprint: 1,
            inner: .uint64(30, in: 0 ... 100),
            bound: .bind(
                fingerprint: 1,
                inner: .uint64(20, in: 0 ... 100),
                bound: .uint64(5, in: 0 ... 100)
            )
        ))
        let binds = graph.liveNodeIDs.compactMap { nodeID -> (Int, BindMetadata)? in
            guard case let .bind(metadata) = graph.nodes[nodeID].kind else {
                return nil
            }
            return (nodeID, metadata)
        }
        try #require(binds.count == 2)
        #expect(binds[0].1.bindPath != binds[1].1.bindPath)
        for (nodeID, metadata) in binds {
            #expect(graph.bindNodeID(fingerprint: 1, path: metadata.bindPath) == nodeID)
            #expect(graph.bindNodeID(fingerprint: 2, path: metadata.bindPath) == nil)
        }
        #expect(graph.composableNestedBind(under: binds[0].0, seenBindFingerprints: [1]) == nil)
    }

    @Test("Inactive binds cannot satisfy a lifted bind lookup")
    func inactiveBindsAreExcluded() throws {
        let graph = ChoiceGraph.build(from: .pickSite(
            fingerprint: 3,
            selected: 1,
            branches: [
                .bind(fingerprint: 17, inner: .uint64(1), bound: .uint64(2)),
                .bind(fingerprint: 19, inner: .uint64(3), bound: .uint64(4)),
            ]
        ))
        let inactive = try #require(graph.nodes.first { node in
            guard case let .bind(metadata) = node.kind else {
                return false
            }
            return metadata.fingerprint == 17
        })
        guard case let .bind(metadata) = inactive.kind else {
            Issue.record("Expected an inactive bind")
            return
        }
        #expect(inactive.positionRange == nil)
        #expect(graph.bindNodeID(fingerprint: 17, path: metadata.bindPath) == nil)
    }

    @Test("Branching dependencies are not treated as a composable chain")
    func branchingDependenciesEndComposition() throws {
        let graph = ChoiceGraph.build(from: .bind(
            fingerprint: 1,
            inner: .uint64(30),
            bound: .group([
                .bind(fingerprint: 2, inner: .uint64(20), bound: .uint64(5)),
                .bind(fingerprint: 3, inner: .uint64(10), bound: .uint64(6)),
            ])
        ))
        let root = try #require(graph.bindNodeID(fingerprint: 1, path: []))
        #expect(graph.composableNestedBind(under: root, seenBindFingerprints: [1]) == nil)
    }
}
