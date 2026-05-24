//
//  ChoiceGraph+Lifecycle.swift
//  Exhaust
//

// MARK: - Mutation Application

package extension ChoiceGraph {
    /// Applies an encoder-reported mutation to the graph.
    ///
    /// Value-only leaf changes (no `mayReshape`) are applied in place — the graph structure is unchanged and only leaf metadata is rewritten. All structural mutations (reshape, removal, pivot, substitution, migration, swap, reorder) return ``ChangeApplication/requiresFullRebuild`` true, delegating the rebuild to the scheduler.
    mutating func apply(_ mutation: ProjectedMutation) -> ChangeApplication {
        var application = ChangeApplication()
        switch mutation {
            case let .leafValues(changes):
                if changes.contains(where: \.mayReshape) {
                    application.requiresFullRebuild = true
                } else {
                    for change in changes {
                        applyLeafValueWrite(change, into: &application)
                    }
                }
            case .sequenceElementsRemoved,
                 .branchSelected,
                 .selfSimilarReplaced,
                 .descendantPromoted,
                 .sequenceElementsMigrated,
                 .siblingsSwapped,
                 .sequenceReordered:
                application.requiresFullRebuild = true
        }
        return application
    }

    /// Rewrites a single leaf's ``ChooseBitsMetadata/value`` in place, tracking the touched node.
    private mutating func applyLeafValueWrite(
        _ change: LeafChange,
        into application: inout ChangeApplication
    ) {
        applyLeafValueWrite(change)
        application.touchedNodeIDs.insert(change.leafNodeID)
    }

    /// Rewrites a single leaf's ``ChooseBitsMetadata/value`` in place.
    mutating func applyLeafValueWrite(_ change: LeafChange) {
        guard change.leafNodeID < nodes.count else { return }
        guard case let .chooseBits(metadata) = nodes[change.leafNodeID].kind else { return }
        let updatedMetadata = ChooseBitsMetadata(
            typeTag: metadata.typeTag,
            validRange: metadata.validRange,
            isRangeExplicit: metadata.isRangeExplicit,
            value: change.newValue
        )
        nodes[change.leafNodeID] = nodes[change.leafNodeID].with(kind: .chooseBits(updatedMetadata))
    }
}
