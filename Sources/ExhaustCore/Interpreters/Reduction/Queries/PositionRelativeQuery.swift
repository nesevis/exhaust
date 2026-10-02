/// Adds field-specific tandem hypotheses within repeated sequence elements without requiring whole-element equality.
///
/// The nearest sequence owns each role. Nested sequences remain separate, and pick/bind fingerprints distinguish generator sites that share a positional path. Correspondence supplies a candidate, not evidence that the property treats the fields alike.
enum PositionRelativeQuery {
    /// Ignores element ordinals while retaining internal paths, generator contexts, and leaf domains.
    static func build(graph: ChoiceGraph) -> [QueryHelpers.LeafGroup] {
        var groups: [Role: [Int]] = [:]
        for nodeID in graph.leafNodes {
            guard let role = role(for: nodeID, graph: graph) else {
                continue
            }
            groups[role, default: []].append(nodeID)
        }
        return groups.filter { _, nodeIdentifiers in
            nodeIdentifiers.count >= 2 && nodeIdentifiers.contains { QueryHelpers.isOffTarget($0, graph: graph) }
        }
        .map { role, nodeIdentifiers in
            QueryHelpers.LeafGroup(typeTag: role.typeTag, nodeIDs: nodeIdentifiers.sorted())
        }
        .sorted { $0.position(in: graph) < $1.position(in: graph) }
    }

    /// Stops at the nearest sequence so equal offsets in unrelated collections never imply a shared field role.
    private static func role(for nodeID: Int, graph: ChoiceGraph) -> Role? {
        let leaf = graph.nodes[nodeID]
        guard leaf.scopeAnnotation.isDepthControl == false,
              leaf.scopeAnnotation.isLaneControl == false,
              case let .chooseBits(metadata) = leaf.kind
        else {
            return nil
        }
        var contexts: [Context] = []
        var parentID = leaf.parent
        while let currentID = parentID {
            let parent = graph.nodes[currentID]
            switch parent.kind {
                case .sequence:
                    guard parent.children.count >= 2 else {
                        return nil
                    }
                    return Role(
                        sequenceNodeID: currentID,
                        path: Array(leaf.choicePath.dropFirst(parent.choicePath.count + 1)),
                        contexts: contexts,
                        typeTag: metadata.typeTag,
                        validRange: metadata.validRange,
                        isRangeExplicit: metadata.isRangeExplicit,
                        payload: metadata.typeTagPayload
                    )
                case let .pick(metadata):
                    contexts.append(.pick(fingerprint: metadata.fingerprint))
                case let .bind(metadata):
                    contexts.append(.bind(fingerprint: metadata.fingerprint))
                case .zip:
                    contexts.append(.zip)
                case .chooseBits, .just:
                    return nil
            }
            parentID = parent.parent
        }
        return nil
    }

    /// Omits current values so a field remains a role even when other fields or occurrences differ.
    private struct Role: Hashable {
        let sequenceNodeID: Int
        let path: ChoicePath
        let contexts: [Context]
        let typeTag: TypeTag
        let validRange: ClosedRange<UInt64>?
        let isRangeExplicit: Bool
        let payload: TypeTagPayload?
    }

    /// Supplements positional paths with generator fingerprints and zip context, since resize wrappers also emit group-child steps without a zip node.
    private enum Context: Hashable {
        case zip
        case pick(fingerprint: UInt64)
        case bind(fingerprint: UInt64)
    }
}
