//
//  PivotLeafFill.swift
//  Exhaust
//

// MARK: - Pivot Leaf Fill

/// Leaf content for the arm a branch pivot moves to.
///
/// Only ``reductionTarget`` is chosen to be small. The others are chosen to fail the property, because value search minimizes an accepted pivot afterwards.
enum PivotLeafFill: CaseIterable {
    /// Every leaf at its reduction target.
    case reductionTarget
    /// The arm as last materialized: a free sample of its domain.
    case recorded
    /// Every ranged leaf at the bound farthest from its reduction target, for a threshold a sample can miss.
    case farthestFromTarget
    /// Copies compatible current fields into a minimal seed. Dynamic subtrees are excluded, and the property decides whether the copied inputs preserve failure.
    case transplanted

    /// Prepares the arm's seed; the transplanted fill additionally needs current graph values before splicing.
    func seed(for branch: ChoiceTree) -> ChoiceTree {
        switch self {
            case .reductionTarget, .transplanted:
                branch.minimizingLeaves
            case .recorded:
                branch
            case .farthestFromTarget:
                branch.maximizingLeaves
        }
    }
}
