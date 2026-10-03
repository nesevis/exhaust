import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Choice tree leaf mapping")
struct ChoiceTreeLeafMappingTests {
    @Test("Leaf fills preserve zip and ordinary-group framing", arguments: PivotLeafFill.allCases)
    func leafFillsPreserveFraming(fill: PivotLeafFill) {
        let tree = ChoiceTree.group(
            [.uint64(37, in: 0 ... 100), .group([.uint64(12, in: 0 ... 100)])],
            isOpaque: true,
            isZip: true
        )
        let original = ChoiceSequence.flatten(tree)
        let filled = ChoiceSequence.flatten(fill.seed(for: tree))
        #expect(filled.filter { $0.value == nil } == original.filter { $0.value == nil })
        #expect(filled.count == original.count)
    }

    @Test("Leaf mapping preserves markers and length across nested tree shapes", arguments: framingTrees())
    func mappingPreservesFraming(tree: ChoiceTree) {
        let original = ChoiceSequence.flatten(tree)
        let mappedTrees = [
            tree.mappingLeaves { value, _ in value },
            tree.minimizingLeaves,
            tree.maximizingLeaves,
        ]
        for mapped in mappedTrees {
            let flattened = ChoiceSequence.flatten(mapped)
            #expect(flattened.filter { $0.value == nil } == original.filter { $0.value == nil })
            #expect(flattened.count == original.count)
        }
    }
}

/// Combines every tree case with ordinary, opaque, and zip groups so framing is checked independently of pivot construction.
private func framingTrees() -> [ChoiceTree] {
    let leaf = ChoiceTree.uint64(37, in: 0 ... 100)
    let children: [ChoiceTree] = [.just, .getSize(10), leaf]
    var trees = children
    for isOpaque in [false, true] {
        for isZip in [false, true] {
            trees.append(.group(children, isOpaque: isOpaque, isZip: isZip))
        }
    }
    let seeds = trees
    for seed in seeds {
        trees.append(.group([seed, leaf], isOpaque: true, isZip: true))
        trees.append(.sequence(elements: [seed, leaf], metadata: .init(validRange: nil)))
        trees.append(.resize(newSize: 10, choices: [seed, leaf]))
        trees.append(.bind(fingerprint: 11, inner: seed, bound: leaf))
        for selected in [0, 1] {
            trees.append(.pickSite(fingerprint: 42, selected: selected, branches: [seed, leaf]))
        }
    }
    return trees
}
