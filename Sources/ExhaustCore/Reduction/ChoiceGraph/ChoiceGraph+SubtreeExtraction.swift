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
        matchingPath path: ChoicePath
    ) -> ChoiceTree? {
        walkForPathMatch(tree: tree, path: path, pathIndex: 0)
    }

    /// Recursive walk used by ``extractBoundSubtree(from:matchingPath:)``. Returns the bound child subtree when `path` is fully consumed at a non-getSize bind, or nil on mismatch.
    ///
    /// Transparent variants (``ChoiceTree/branch``, getSize-inner ``ChoiceTree/bind``) descend without consuming a step. All other structural descents must match the next step at `pathIndex`.
    private static func walkForPathMatch(
        tree: ChoiceTree,
        path: ChoicePath,
        pathIndex: Int
    ) -> ChoiceTree? {
        switch tree {
            case .choice, .just, .getSize:
                // Terminals — cannot contain further binds.
                return nil

            case let .sequence(elements, _):
                guard let step = path.step(at: pathIndex),
                      case let .sequenceChild(index) = step,
                      elements.indices.contains(index)
                else {
                    return nil
                }
                return walkForPathMatch(
                    tree: elements[index],
                    path: path,
                    pathIndex: pathIndex + 1
                )

            case let .branch(b):
                // Transparent wrapper — pass through without consuming a step.
                return walkForPathMatch(tree: b.choice, path: path, pathIndex: pathIndex)

            case let .group(array, _, _):
                if isPickSite(array) {
                    guard let step = path.step(at: pathIndex),
                          case let .pickBranch(targetID) = step
                    else {
                        return nil
                    }
                    for element in array {
                        // The selected element carries the originally-picked branch.
                        if case let .branch(b) = element, b.isSelected,
                           b.id == targetID
                        {
                            return walkForPathMatch(
                                tree: element,
                                path: path,
                                pathIndex: pathIndex + 1
                            )
                        }
                    }
                    return nil
                }
                // Regular zip group.
                guard let step = path.step(at: pathIndex),
                      case let .groupChild(index) = step,
                      array.indices.contains(index)
                else {
                    return nil
                }
                return walkForPathMatch(
                    tree: array[index],
                    path: path,
                    pathIndex: pathIndex + 1
                )

            case let .bind(_, inner, bound):
                if inner.isGetSize {
                    // getSize-bind is transparent in the graph — pass through.
                    return walkForPathMatch(tree: bound, path: path, pathIndex: pathIndex)
                }
                if pathIndex == path.count {
                    // This is the target bind — return its bound child.
                    return bound
                }
                guard let step = path.step(at: pathIndex) else {
                    return nil
                }
                switch step {
                    case .bindBound:
                        return walkForPathMatch(
                            tree: bound,
                            path: path,
                            pathIndex: pathIndex + 1
                        )
                    case .bindInner:
                        return walkForPathMatch(
                            tree: inner,
                            path: path,
                            pathIndex: pathIndex + 1
                        )
                    default:
                        return nil
                }

            case let .resize(_, choices):
                guard let step = path.step(at: pathIndex),
                      case let .groupChild(index) = step,
                      choices.indices.contains(index)
                else {
                    return nil
                }
                return walkForPathMatch(
                    tree: choices[index],
                    path: path,
                    pathIndex: pathIndex + 1
                )
        }
    }

    /// Pick-site detection that mirrors ``ChoiceGraphBuilder/detectPickSite(_:)``: every child must be `.branch`, and at least one must be selected.
    private static func isPickSite(_ array: [ChoiceTree]) -> Bool {
        guard array.allSatisfy({ $0.isBranch }) else {
            return false
        }
        return array.contains(where: { $0.isSelected })
    }
}
