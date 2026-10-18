import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Intermediate bind graphs")
struct IntermediateBindGraphTests {
    @Test("Generated trees preserve controller topology in partial graphs")
    func generatedControllerTopology() throws {
        try exhaustCheck(ChoiceTreeGenerators.trees, maxIterations: 500) { tree in
            Self.hasMatchingControllerTopology(tree)
        }
    }

    @Test("Scalar arrays keep their spans without per-element nodes")
    func preservesControllerTopology() {
        let array = ChoiceTree.sequence(
            elements: Array(repeating: ChoiceTree.uint64(1, in: 0 ... 10), count: 200),
            metadata: .init(validRange: 200 ... 200, isRangeExplicit: true)
        )
        let tree = ChoiceTree.group([
            array,
            .bind(fingerprint: 11, inner: ChoiceTree.uint64(3, in: 0 ... 10), bound: .group([
                array,
                .bind(fingerprint: 22, inner: ChoiceTree.uint64(2, in: 0 ... 10), bound: array),
            ])),
        ])
        let full = ChoiceGraphBuilder.build(from: tree)
        let compact = ChoiceGraphBuilder.buildControllerTopology(from: tree)
        #expect(compact.nodes.count < full.nodes.count / 20)
        #expect(Self.hasMatchingControllerTopology(tree))
    }

    @Test("Arrays containing binds retain branching dependencies")
    func preservesBindsInsideArrays() {
        let elements: [ChoiceTree] = [
            .bind(fingerprint: 22, inner: ChoiceTree.uint64(2, in: 0 ... 10), bound: ChoiceTree.uint64(1, in: 0 ... 10)),
            .bind(fingerprint: 33, inner: ChoiceTree.uint64(2, in: 0 ... 10), bound: ChoiceTree.uint64(1, in: 0 ... 10)),
        ]
        let tree = ChoiceTree.bind(
            fingerprint: 11,
            inner: ChoiceTree.uint64(3, in: 0 ... 10),
            bound: .sequence(elements: elements, metadata: .init(validRange: 2 ... 2))
        )
        let full = ChoiceGraphBuilder.build(from: tree)
        let compact = ChoiceGraphBuilder.buildControllerTopology(from: tree)
        #expect(compact.nodes.count == full.nodes.count)
        #expect(compact.composableNestedBind(under: 0, seenBindFingerprints: [11]) == nil)
        #expect(compact.nodes.map(\.positionRange) == full.nodes.map(\.positionRange))
    }

    // MARK: - Helpers

    /// Every live bind in the complete graph has a counterpart in the partial graph with the same span, the same controller leaf, and the same composable nested bind. Binds in unselected arms have no span, and bind lookup cannot address them in either graph.
    private static func hasMatchingControllerTopology(_ tree: ChoiceTree) -> Bool {
        let full = ChoiceGraphBuilder.build(from: tree)
        let compact = ChoiceGraphBuilder.buildControllerTopology(from: tree)
        return full.nodes.allSatisfy { node in
            guard case let .bind(metadata) = node.kind, node.positionRange != nil else {
                return true
            }
            guard let compactID = compact.bindNodeID(fingerprint: metadata.fingerprint, path: metadata.bindPath) else {
                return false
            }
            let compactNode = compact.nodes[compactID]
            let source = full.nodes[node.children[metadata.innerChildIndex]]
            let compactSource = compact.nodes[compactNode.children[metadata.innerChildIndex]]
            guard case let .chooseBits(original) = source.kind,
                  case let .chooseBits(rebuilt) = compactSource.kind
            else {
                return false
            }
            let seen: Set<UInt64> = [metadata.fingerprint]
            let nestedBind = full.composableNestedBind(under: node.id, seenBindFingerprints: seen)
            let compactNestedBind = compact.composableNestedBind(under: compactID, seenBindFingerprints: seen)
            return compactNode.positionRange == node.positionRange
                && compactSource.positionRange == source.positionRange
                && compactSource.choicePath == source.choicePath
                && rebuilt.value == original.value
                && rebuilt.validRange == original.validRange
                && compactNestedBind?.metadata.fingerprint == nestedBind?.metadata.fingerprint
        }
    }
}
