//
//  BindPath.swift
//  Exhaust
//

// MARK: - Bind Path

/// A single descent step in a ``BindPath``.
///
/// Each step identifies which child of a ``ChoiceTree`` variant to descend into when walking from the tree root to a target bind. Transparent variants (``ChoiceTree/branch``, ``ChoiceTree/selected``, and getSize-inner ``ChoiceTree/bind``) do not consume a step — they are walked through without a path increment.
package enum BindPathStep: Equatable, Hashable, Sendable {
    /// Descend into the nth element of a ``ChoiceTree/sequence(_:_:_:)``.
    case sequenceChild(Int)

    /// Descend into the nth element of a regular (non-pick) ``ChoiceTree/group(_:_:)`` or a ``ChoiceTree/resize(_:_:)``.
    case groupChild(Int)

    /// Descend into the ``ChoiceTree/selected(_:)`` child at a pick site whose wrapped ``ChoiceTree/branch(_:_:_:_:_:)`` has the given id.
    case pickBranch(UInt64)

    /// Descend into the bound child of a non-getSize ``ChoiceTree/bind(_:_:)``.
    case bindBound
}

/// A structural path from a ``ChoiceTree`` root to a bind node.
///
/// Used by ``ChoiceGraph/extractBoundSubtree(from:matchingPath:)`` to locate a specific bind in a freshly materialized tree in a way that survives upstream structural divergence. Offset-based lookup fails when an upstream change shifts sequence positions; path-based lookup remains stable as long as the tree shape from root to the target bind does not change.
///
/// The root bind of a tree has the empty path. A bind reached by descending into the bound child of another bind has path `[.bindBound]`. Nested binds under sequences, groups, or picks accumulate steps accordingly.
package typealias BindPath = [BindPathStep]
