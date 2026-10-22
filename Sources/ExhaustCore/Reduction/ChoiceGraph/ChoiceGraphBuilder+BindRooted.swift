// MARK: - Bind-Rooted Build

extension ChoiceGraphBuilder {
    /// Builds only the bind subtree needed after a bound-value lift.
    ///
    /// Positions, paths, depths, and scope annotations match a full build, but node IDs start at zero and belong only to this graph.
    ///
    /// - Returns: The graph rooted at node zero, or nil if the path does not identify an active, non-getSize bind with `fingerprint`. Paths through another bind's inner subtree also return nil: use ``build(from:)`` to retain the outer controller annotation.
    static func buildBind(
        at bindPath: ChoicePath,
        fingerprint: UInt64,
        in tree: ChoiceTree,
        omittingScalarSequenceElements: Bool
    ) -> (graph: ChoiceGraph, bindNodeID: Int)? {
        guard let location = locateBind(in: tree, remainingPath: bindPath[...], offset: 0, bindDepth: 0, fingerprint: fingerprint) else {
            return nil
        }
        var builder = ChoiceGraphBuilder(omittingScalarSequenceElements: omittingScalarSequenceElements)
        // Lifted bind scopes repeatedly grow through the first few buffer capacities. Start at eight to avoid those copies; larger subtrees still grow normally.
        builder.nodes.reserveCapacity(8)
        builder.containmentEdges.reserveCapacity(8)
        _ = builder.walk(location.bind, offset: location.offset, parent: nil, bindDepth: location.bindDepth, path: bindPath)
        return (builder.finishedGraph(), 0)
    }

    /// Locates an active bind with the full walk's offset and depth, counting skipped siblings through ``ChoiceTree/flattenedEntryCount``.
    private static func locateBind(
        in tree: ChoiceTree,
        remainingPath: ChoicePath.SubSequence,
        offset: Int,
        bindDepth: Int,
        fingerprint: UInt64
    ) -> (bind: ChoiceTree, offset: Int, bindDepth: Int)? {
        switch tree {
            case .choice, .just, .getSize:
                return nil

            case let .sequence(elements, _):
                guard case let .sequenceChild(index)? = remainingPath.first, elements.indices.contains(index) else {
                    return nil
                }
                return locateBind(
                    in: elements[index],
                    remainingPath: remainingPath.dropFirst(),
                    offset: offset + 1 + Self.flattenedEntryCount(of: elements[..<index]),
                    bindDepth: bindDepth,
                    fingerprint: fingerprint
                )

            case let .branch(branch):
                return locateBind(in: branch.choice, remainingPath: remainingPath, offset: offset, bindDepth: bindDepth, fingerprint: fingerprint)

            case let .group(array, _, _):
                if let pickSite = detectPickSite(array) {
                    guard case let .pickBranch(branchID)? = remainingPath.first,
                          branchID == pickSite.selectedID,
                          let selected = array.first(where: { $0.isSelected })
                    else {
                        return nil
                    }
                    // Group open and branch marker precede the selected branch's content.
                    return locateBind(in: selected, remainingPath: remainingPath.dropFirst(), offset: offset + 2, bindDepth: bindDepth, fingerprint: fingerprint)
                }
                guard case let .groupChild(index)? = remainingPath.first, array.indices.contains(index) else {
                    return nil
                }
                return locateBind(
                    in: array[index],
                    remainingPath: remainingPath.dropFirst(),
                    offset: offset + 1 + Self.flattenedEntryCount(of: array[..<index]),
                    bindDepth: bindDepth,
                    fingerprint: fingerprint
                )

            case let .bind(bindFingerprint, inner, bound):
                if inner.isGetSize {
                    return locateBind(in: bound, remainingPath: remainingPath, offset: offset + 1, bindDepth: bindDepth, fingerprint: fingerprint)
                }
                guard let step = remainingPath.first else {
                    guard bindFingerprint == fingerprint else {
                        return nil
                    }
                    return (tree, offset, bindDepth)
                }
                guard case .bindBound = step else {
                    return nil
                }
                return locateBind(
                    in: bound,
                    remainingPath: remainingPath.dropFirst(),
                    offset: offset + 1 + inner.flattenedEntryCount,
                    bindDepth: bindDepth + 1,
                    fingerprint: fingerprint
                )

            case let .resize(_, choices):
                guard case let .groupChild(index)? = remainingPath.first, choices.indices.contains(index) else {
                    return nil
                }
                return locateBind(
                    in: choices[index],
                    remainingPath: remainingPath.dropFirst(),
                    offset: offset + 1 + Self.flattenedEntryCount(of: choices[..<index]),
                    bindDepth: bindDepth,
                    fingerprint: fingerprint
                )
        }
    }

    private static func flattenedEntryCount(of trees: ArraySlice<ChoiceTree>) -> Int {
        var count = 0
        for tree in trees {
            count += tree.flattenedEntryCount
        }
        return count
    }
}
