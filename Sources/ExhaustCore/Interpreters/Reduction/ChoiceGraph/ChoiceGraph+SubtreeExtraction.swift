//
//  ChoiceGraph+SubtreeExtraction.swift
//  Exhaust
//

// MARK: - Bound Subtree Extraction

extension ChoiceGraph {
    /// Walks `tree` following the structural steps in `path` to locate a bind node, and returns that bind's bound child subtree.
    ///
    /// Used by ``ChoiceGraph/applyBindReshape(forLeaf:freshTree:into:)`` to extract the new bound subtree from the materializer's freshly produced tree, given the target bind's ``BindMetadata/bindPath`` from the pre-mutation graph. Path-based identification remains stable across upstream-induced structural divergence, whereas the prior offset-based lookup would silently match a different bind when the sequence layout shifted.
    ///
    /// Returns `nil` if the path does not resolve to a non-getSize bind inside `tree`. The caller falls back to a full graph rebuild in that case.
    static func extractBoundSubtree(
        from tree: ChoiceTree,
        matchingPath path: BindPath
    ) -> ChoiceTree? {
        walkForPathMatch(tree: tree, remainingPath: path[...])
    }

    /// Recursive walk used by ``extractBoundSubtree(from:matchingPath:)``. Returns the bound child subtree when `remainingPath` is fully consumed at a non-getSize bind, or nil on mismatch.
    ///
    /// Transparent variants (``ChoiceTree/branch``, ``ChoiceTree/selected``, getSize-inner ``ChoiceTree/bind``) descend without consuming a step. All other structural descents must match the next step in `remainingPath`.
    private static func walkForPathMatch(
        tree: ChoiceTree,
        remainingPath: ArraySlice<BindPathStep>
    ) -> ChoiceTree? {
        switch tree {
        case .choice, .just, .getSize:
            // Terminals — cannot contain further binds.
            return nil

        case let .sequence(_, elements, _):
            guard let step = remainingPath.first,
                  case let .sequenceChild(index) = step,
                  elements.indices.contains(index)
            else { return nil }
            return walkForPathMatch(
                tree: elements[index],
                remainingPath: remainingPath.dropFirst()
            )

        case let .branch(_, _, _, _, choice):
            // Transparent wrapper — pass through without consuming a step.
            return walkForPathMatch(tree: choice, remainingPath: remainingPath)

        case let .group(array, _):
            if isPickSite(array) {
                guard let step = remainingPath.first,
                      case let .pickBranch(targetID) = step
                else { return nil }
                for element in array {
                    // The selected element wraps the originally-picked branch.
                    if case let .selected(inner) = element,
                       case let .branch(id, _, _, _, _) = inner,
                       id == targetID
                    {
                        return walkForPathMatch(
                            tree: element,
                            remainingPath: remainingPath.dropFirst()
                        )
                    }
                }
                return nil
            }
            // Regular zip group.
            guard let step = remainingPath.first,
                  case let .groupChild(index) = step,
                  array.indices.contains(index)
            else { return nil }
            return walkForPathMatch(
                tree: array[index],
                remainingPath: remainingPath.dropFirst()
            )

        case let .bind(inner, bound):
            if inner.isGetSize {
                // getSize-bind is transparent in the graph — pass through.
                return walkForPathMatch(tree: bound, remainingPath: remainingPath)
            }
            if remainingPath.isEmpty {
                // This is the target bind — return its bound child.
                return bound
            }
            guard let step = remainingPath.first,
                  case .bindBound = step
            else { return nil }
            return walkForPathMatch(
                tree: bound,
                remainingPath: remainingPath.dropFirst()
            )

        case let .resize(_, choices):
            guard let step = remainingPath.first,
                  case let .groupChild(index) = step,
                  choices.indices.contains(index)
            else { return nil }
            return walkForPathMatch(
                tree: choices[index],
                remainingPath: remainingPath.dropFirst()
            )

        case let .selected(inner):
            // Transparent wrapper — pass through without consuming a step.
            return walkForPathMatch(tree: inner, remainingPath: remainingPath)
        }
    }

    /// Pick-site detection that mirrors ``ChoiceGraphBuilder/detectPickSite(_:)``: every child must be `.branch` or `.selected`, and at least one must be `.selected`.
    private static func isPickSite(_ array: [ChoiceTree]) -> Bool {
        guard array.allSatisfy({ $0.isBranch || $0.isSelected }) else {
            return false
        }
        return array.contains(where: \.isSelected)
    }
}
