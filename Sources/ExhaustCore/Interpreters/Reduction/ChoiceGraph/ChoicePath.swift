//
//  ChoicePath.swift
//  Exhaust
//

// MARK: - Choice Path

/// A single descent step in a ``ChoicePath``.
///
/// Each step identifies which child of a ``ChoiceTree`` variant to descend into when walking from the tree root to a target node. Transparent variants (``ChoiceTree/branch``, getSize-inner ``ChoiceTree/bind``) do not consume a step — they are walked through without a path increment.
package enum ChoicePathStep: Equatable, Hashable {
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
/// Survives graph rebuilds as long as the tree shape above the addressed node does not change. Used to carry convergence records, warm starts, and other per-node state across rebuilds without relying on unstable sequential node IDs.
///
/// Two nodes in successive graphs with the same ``ChoicePath`` are the same logical node — their encoder state can be transferred directly.
package typealias ChoicePath = [ChoicePathStep]
