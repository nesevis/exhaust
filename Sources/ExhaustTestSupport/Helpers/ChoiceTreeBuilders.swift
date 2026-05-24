import ExhaustCore

// MARK: - Leaf Construction

package extension ChoiceTree {
    /// An unsigned integer leaf with an explicit valid range.
    ///
    /// ```swift
    /// .uint64(42, in: 0...100)
    /// ```
    static func uint64(_ value: UInt64, in range: ClosedRange<UInt64> = 0 ... UInt64.max) -> ChoiceTree {
        .choice(
            ChoiceValue(value, tag: .uint64),
            .init(validRange: range, isRangeExplicit: range != 0 ... UInt64.max)
        )
    }

    /// A signed 64-bit integer leaf. The valid range spans the full type width.
    ///
    /// ```swift
    /// .int64(-7)
    /// ```
    static func int64(_ value: Int64) -> ChoiceTree {
        .choice(
            ChoiceValue(value, tag: .int64),
            .init(validRange: nil, isRangeExplicit: false)
        )
    }

    /// A double-precision floating-point leaf. The valid range spans the full type width.
    ///
    /// ```swift
    /// .double(3.14)
    /// ```
    static func double(_ value: Double) -> ChoiceTree {
        .choice(
            ChoiceValue(value, tag: .double),
            .init(validRange: nil, isRangeExplicit: false)
        )
    }

    /// A sequence of unsigned integer leaves with a shared valid range.
    ///
    /// ```swift
    /// .uint64Sequence([10, 20, 30], in: 0...100)
    /// ```
    static func uint64Sequence(
        _ values: [UInt64],
        in range: ClosedRange<UInt64> = 0 ... UInt64.max
    ) -> ChoiceTree {
        .sequence(
            length: UInt64(values.count),
            elements: values.map { .uint64($0, in: range) },
            .init(validRange: nil, isRangeExplicit: false)
        )
    }

    /// A zip (group) of unsigned integer leaves with a shared valid range.
    ///
    /// ```swift
    /// .uint64Zip([10, 20, 30], in: 0...100)
    /// ```
    static func uint64Zip(
        _ values: [UInt64],
        in range: ClosedRange<UInt64> = 0 ... UInt64.max
    ) -> ChoiceTree {
        .group(values.map { .uint64($0, in: range) })
    }
}

// MARK: - Pick Site Construction

package extension ChoiceTree {
    /// A pick site (oneOf) with multiple branches, one of which is selected.
    ///
    /// ```swift
    /// .pickSite(
    ///     fingerprint: 42,
    ///     selected: 1,
    ///     branches: [.just, .uint64(10, in: 0...100)]
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - fingerprint: Self-similarity group identifier.
    ///   - selected: Zero-based index of the selected branch.
    ///   - branches: Content of each branch. The branch at `selected` is marked active.
    static func pickSite(
        fingerprint: UInt64,
        selected: Int,
        branches: [ChoiceTree]
    ) -> ChoiceTree {
        let branchCount = UInt64(branches.count)
        let branchNodes = branches.enumerated().map { index, content in
            ChoiceTree.branch(
                fingerprint: fingerprint,
                weight: 1,
                id: UInt64(index),
                branchCount: branchCount,
                choice: content,
                isSelected: index == selected
            )
        }
        return .group(branchNodes)
    }
}

// MARK: - Graph Fixture

/// A ``ChoiceTree`` paired with its pre-built ``ChoiceGraph`` and flattened ``ChoiceSequence``.
///
/// Eliminates the repeated `let graph = ChoiceGraph.build(from: tree); let sequence = ChoiceSequence.flatten(tree)` pattern.
package struct GraphFixture {
    package let tree: ChoiceTree
    package let graph: ChoiceGraph
    package let sequence: ChoiceSequence

    package init(_ tree: ChoiceTree) {
        self.tree = tree
        graph = ChoiceGraph.build(from: tree)
        sequence = ChoiceSequence.flatten(tree)
    }
}
