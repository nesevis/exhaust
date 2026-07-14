//
//  ChoicePath.swift
//  Exhaust
//

// MARK: - Choice Path

/// A single descent step in a ``ChoicePath``.
///
/// Each step identifies which child of a ``ChoiceTree`` variant to descend into when walking from the tree root to a target node. Transparent variants (``ChoiceTree/branch``, getSize-inner ``ChoiceTree/bind``) do not consume a step — they are walked through without a path increment.
package enum ChoicePathStep: Equatable, Hashable, Sendable {
    /// Descend into the nth element of a ``ChoiceTree/sequence``.
    case sequenceChild(Int)

    /// Descend into the nth element of a regular (non-pick) ``ChoiceTree/group`` or ``ChoiceTree/resize``.
    case groupChild(Int)

    /// Descend into the active branch at a pick site with the given branch id.
    case pickBranch(UInt64)

    /// Descend into the inner child of a non-getSize ``ChoiceTree/bind``.
    case bindInner

    /// Descend into the bound child of a non-getSize ``ChoiceTree/bind``.
    case bindBound
}

/// A structural address from a ``ChoiceTree`` root to any node in the tree.
///
/// The same path addresses the same position while the shape above it remains unchanged, but it does not identify the position's occupant across tree versions. For example, deleting a sequence element moves later elements into earlier paths.
///
/// Cross-rebuild consumers use the path as the first component of a continuity check instead of relying on unstable node IDs. Each state category must add the guards its semantics require. Convergence transfer also checks the type tag and current bit pattern, except when the scheduler knows that an accepted value change made the old graph value stale without shifting the path.
package typealias ChoicePath = [ChoicePathStep]
