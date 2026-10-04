import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Intermediate bind graphs")
struct IntermediateBindGraphTests {
    @Test("Generated trees preserve controller topology in partial graphs")
    func generatedControllerTopology() throws {
        try exhaustCheck(Self.trees, maxIterations: 500) { tree in
            Self.hasMatchingControllerTopology(tree)
        }
    }

    @Test("Scalar arrays keep their spans without per-element nodes")
    func preservesControllerTopology() {
        let array = ChoiceTree.sequence(
            elements: Array(repeating: Self.choice(1), count: 200),
            metadata: .init(validRange: 200 ... 200, isRangeExplicit: true)
        )
        let tree = ChoiceTree.group([
            array,
            .bind(fingerprint: 11, inner: Self.choice(3), bound: .group([
                array,
                .bind(fingerprint: 22, inner: Self.choice(2), bound: array),
            ])),
        ])
        let full = ChoiceGraphBuilder.build(from: tree)
        let compact = ChoiceGraphBuilder.build(from: tree, omittingScalarSequenceElements: true)
        #expect(full.isComplete)
        #expect(compact.isComplete == false)
        #expect(compact.nodes.count < full.nodes.count / 20)
        #expect(Self.hasMatchingControllerTopology(tree))
    }

    @Test("Arrays containing binds retain branching dependencies")
    func preservesBindsInsideArrays() {
        let elements: [ChoiceTree] = [
            .bind(fingerprint: 22, inner: Self.choice(2), bound: Self.choice(1)),
            .bind(fingerprint: 33, inner: Self.choice(2), bound: Self.choice(1)),
        ]
        let tree = ChoiceTree.bind(
            fingerprint: 11,
            inner: Self.choice(3),
            bound: .sequence(elements: elements, metadata: .init(validRange: 2 ... 2))
        )
        let full = ChoiceGraphBuilder.build(from: tree)
        let compact = ChoiceGraphBuilder.build(from: tree, omittingScalarSequenceElements: true)
        #expect(compact.nodes.count == full.nodes.count)
        #expect(compact.composableNestedBind(under: 0, seenBindFingerprints: [11]) == nil)
        #expect(compact.nodes.map(\.positionRange) == full.nodes.map(\.positionRange))
    }

    // MARK: - Helpers

    /// Every live bind in the complete graph has a counterpart in the partial graph with the same span, the same controller leaf, and the same composable nested bind. Binds in unselected arms have no span, and bind lookup cannot address them in either graph.
    private static func hasMatchingControllerTopology(_ tree: ChoiceTree) -> Bool {
        let full = ChoiceGraphBuilder.build(from: tree)
        let compact = ChoiceGraphBuilder.build(from: tree, omittingScalarSequenceElements: true)
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

    private static func choice(_ value: UInt64) -> ChoiceTree {
        .choice(ChoiceValue(value, tag: .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
    }

    private static func sequence(_ elements: [ChoiceTree]) -> ChoiceTree {
        let count = UInt64(elements.count)
        return .sequence(elements: elements, metadata: .init(validRange: count ... count, isRangeExplicit: true))
    }

    private static func pick(arms: [ChoiceTree], selected: Int) -> ChoiceTree {
        let branches: [ChoiceTree] = arms.enumerated().map { index, arm in
            .branch(
                fingerprint: 7,
                weight: 1,
                id: UInt64(index),
                branchCount: UInt64(arms.count),
                choice: arm,
                isSelected: index == selected
            )
        }
        return .group(branches)
    }

    private static let leaves = Gen.choose(in: UInt64(0) ... 10).map { Self.choice($0) }

    /// Scalar arrays are the shape the partial builder collapses; binds, picks, and mixed arrays are the shapes it must leave intact around them.
    private static let trees: Generator<ChoiceTree> = Gen.recursive(base: leaves, depthRange: 0 ... 4) { recurse, _ in
        let scalarArrays = Gen.arrayOf(leaves, within: 0 ... 24).map { Self.sequence($0) }
        let binds = Gen.zip(Gen.choose(in: UInt64(1) ... 1000), leaves, recurse()).map { fingerprint, inner, bound in
            ChoiceTree.bind(fingerprint: fingerprint, inner: inner, bound: bound)
        }
        let groups = Gen.arrayOf(recurse(), within: 1 ... 3).map { ChoiceTree.group($0) }
        let mixedArrays = Gen.arrayOf(recurse(), within: 0 ... 3).map { Self.sequence($0) }
        let arms: Generator<[ChoiceTree]> = Gen.arrayOf(recurse(), within: 2 ... 3)
        let selections: Generator<Int> = Gen.choose(in: 0 ... 2)
        let picks: Generator<ChoiceTree> = Gen.zip(arms, selections).map { arms, selected in
            Self.pick(arms: arms, selected: selected % arms.count)
        }
        let choices: [(weight: Int, generator: Generator<ChoiceTree>)] = [
            (1, leaves),
            (2, scalarArrays),
            (2, binds),
            (1, groups),
            (1, mixedArrays),
            (1, picks),
        ]
        return Gen.pick(choices: choices)
    }
}
