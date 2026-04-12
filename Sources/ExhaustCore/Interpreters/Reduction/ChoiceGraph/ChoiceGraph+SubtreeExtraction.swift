//
//  ChoiceGraph+SubtreeExtraction.swift
//  Exhaust
//

// MARK: - Bound Subtree Extraction

extension ChoiceGraph {
    /// Walks `tree` mirroring ``ChoiceGraphBuilder`` offset arithmetic to find the bind node whose own `positionRange.lowerBound` equals `targetOffset`. Returns the bound child subtree of that bind, or nil if no matching bind is found.
    ///
    /// Used by ``applyBindReshape(forLeaf:freshTree:into:)`` to extract the new bound subtree from the materializer's freshly produced tree, given the bind's known offset from the OLD graph. The position-based lookup works because a single bind-inner mutation shifts positions only inside the bound subtree — positions up to and including the bind's own offset are unchanged.
    static func extractBoundSubtree(
        from tree: ChoiceTree,
        bindAtOffset targetOffset: Int
    ) -> ChoiceTree? {
        var result: ChoiceTree?
        _ = walkForBindExtraction(
            tree: tree,
            offset: 0,
            target: targetOffset,
            result: &result
        )
        return result
    }

    /// Recursive walk used by ``extractBoundSubtree(from:bindAtOffset:)``. Returns the number of sequence positions consumed by `tree`, mirroring ``ChoiceGraphBuilder/walk(_:offset:parent:bindDepth:)`` exactly so that the offset arithmetic stays in sync.
    private static func walkForBindExtraction(
        tree: ChoiceTree,
        offset: Int,
        target: Int,
        result: inout ChoiceTree?
    ) -> Int {
        if result != nil { return 0 }

        switch tree {
        case .choice:
            return 1
        case .just:
            return 1
        case .getSize:
            return 0
        case let .sequence(_, elements, _):
            var consumed = 1 // sequence open
            for element in elements {
                consumed += walkForBindExtraction(
                    tree: element,
                    offset: offset + consumed,
                    target: target,
                    result: &result
                )
                if result != nil { break }
            }
            consumed += 1 // sequence close
            return consumed
        case let .branch(_, _, _, _, choice):
            return walkForBindExtraction(
                tree: choice,
                offset: offset,
                target: target,
                result: &result
            )
        case let .group(array, _):
            if isPickSite(array) {
                // Pick site: 2 (group open + branch marker) + selected + 1 (close).
                var consumed = 2
                for element in array where element.isSelected {
                    consumed += walkForBindExtraction(
                        tree: element,
                        offset: offset + consumed,
                        target: target,
                        result: &result
                    )
                    break
                }
                consumed += 1
                return consumed
            }
            // Regular zip group.
            var consumed = 1 // group open
            for child in array {
                consumed += walkForBindExtraction(
                    tree: child,
                    offset: offset + consumed,
                    target: target,
                    result: &result
                )
                if result != nil { break }
            }
            consumed += 1 // group close
            return consumed
        case let .bind(inner, bound):
            if inner.isGetSize {
                // getSize-bind is transparent: 1 (group open) + bound + 1 (group close).
                var consumed = 1
                consumed += walkForBindExtraction(
                    tree: bound,
                    offset: offset + consumed,
                    target: target,
                    result: &result
                )
                consumed += 1
                return consumed
            }
            // Real bind: check if THIS bind is the target.
            if offset == target {
                result = bound
                return 0
            }
            var consumed = 1 // bind open
            consumed += walkForBindExtraction(
                tree: inner,
                offset: offset + consumed,
                target: target,
                result: &result
            )
            if result != nil { return consumed }
            consumed += walkForBindExtraction(
                tree: bound,
                offset: offset + consumed,
                target: target,
                result: &result
            )
            consumed += 1 // bind close
            return consumed
        case let .resize(_, choices):
            var consumed = 1 // group open
            for choice in choices {
                consumed += walkForBindExtraction(
                    tree: choice,
                    offset: offset + consumed,
                    target: target,
                    result: &result
                )
                if result != nil { break }
            }
            consumed += 1 // group close
            return consumed
        case let .selected(inner):
            return walkForBindExtraction(
                tree: inner,
                offset: offset,
                target: target,
                result: &result
            )
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
