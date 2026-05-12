//
//  ChoiceGraph+SubtreeExtraction.swift
//  Exhaust
//

// MARK: - Bound Subtree Extraction

extension ChoiceGraph {
    /// Walks `tree` following the structural steps in `path` to locate a bind node, and returns that bind's bound child subtree.
    ///
    /// Used by ``classifyBind(at:gen:baseSequence:fallbackTree:upstreamLeafNodeID:)`` and ``observeBindTopologies(tree:)`` to extract the bound subtree from a materialized tree, given the target bind's ``BindMetadata/bindPath``. Path-based identification remains stable across upstream-induced structural divergence, whereas offset-based lookup would silently match a different bind when the sequence layout shifted.
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
    /// Transparent variants (``ChoiceTree/branch``, getSize-inner ``ChoiceTree/bind``) descend without consuming a step. All other structural descents must match the next step in `remainingPath`.
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

        case let .branch(_, _, _, _, choice, _):
            // Transparent wrapper — pass through without consuming a step.
            return walkForPathMatch(tree: choice, remainingPath: remainingPath)

        case let .group(array, _):
            if isPickSite(array) {
                guard let step = remainingPath.first,
                      case let .pickBranch(targetID) = step
                else { return nil }
                for element in array {
                    // The selected element carries the originally-picked branch.
                    if case let .branch(_, _, id, _, _, true) = element,
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

        case let .bind(_, inner, bound):
            if inner.isGetSize {
                // getSize-bind is transparent in the graph — pass through.
                return walkForPathMatch(tree: bound, remainingPath: remainingPath)
            }
            if remainingPath.isEmpty {
                // This is the target bind — return its bound child.
                return bound
            }
            guard let step = remainingPath.first else { return nil }
            switch step {
            case .bindBound:
                return walkForPathMatch(
                    tree: bound,
                    remainingPath: remainingPath.dropFirst()
                )
            case .bindInner:
                return walkForPathMatch(
                    tree: inner,
                    remainingPath: remainingPath.dropFirst()
                )
            default:
                return nil
            }

        case let .resize(_, choices):
            guard let step = remainingPath.first,
                  case let .groupChild(index) = step,
                  choices.indices.contains(index)
            else { return nil }
            return walkForPathMatch(
                tree: choices[index],
                remainingPath: remainingPath.dropFirst()
            )

        }
    }

    /// Pick-site detection that mirrors ``ChoiceGraphBuilder/detectPickSite(_:)``: every child must be `.branch`, and at least one must be selected.
    private static func isPickSite(_ array: [ChoiceTree]) -> Bool {
        guard array.allSatisfy({ $0.isBranch }) else {
            return false
        }
        return array.contains(where: \.isSelected)
    }
}
