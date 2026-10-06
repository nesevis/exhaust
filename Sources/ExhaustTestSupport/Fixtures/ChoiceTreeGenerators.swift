import ExhaustCore

/// Generates choice trees directly, for graph and reducer tests that need tree shapes no user generator would produce on demand.
package enum ChoiceTreeGenerators {
    /// Scalar arrays are the shape the partial builder collapses; binds, picks, and mixed arrays are the shapes it must leave intact around them.
    package static let trees: Generator<ChoiceTree> = Gen.recursive(base: leaves, depthRange: 0 ... 4) { recurse, _ in
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

    private static let leaves = Gen.choose(in: UInt64(0) ... 10).map { ChoiceTree.uint64($0, in: 0 ... 10) }

    // MARK: - Helpers

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
}
