/// Adds field-specific tandem hypotheses within repeated sequence elements and zipped fields at recurring pick sites without requiring whole-element equality.
///
/// The nearest sequence owns each role. Outside sequences, the nearest pick site owns zipped fields, with its fingerprint identifying recurring generator sites and its selected branch retained in the relative path. Correspondence supplies a candidate, not evidence that the property treats the fields alike.
enum PositionRelativeQuery {
    /// Ignores sequence element ordinals or paths above recurring pick sites while retaining field paths, generator contexts, and leaf domains.
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

    /// Gives sequences precedence over recurring picks so nested collections never borrow field correspondence from an enclosing generator site.
    private static func role(for nodeID: Int, graph: ChoiceGraph) -> Role? {
        let leaf = graph.nodes[nodeID]
        guard leaf.scopeAnnotation.isDepthControl == false,
              leaf.scopeAnnotation.isLaneControl == false,
              case let .chooseBits(metadata) = leaf.kind
        else {
            return nil
        }
        var contexts: [Context] = []
        var nearestPickRole: Role?
        var hasVisitedPick = false
        var parentID = leaf.parent
        while let currentID = parentID {
            let parent = graph.nodes[currentID]
            switch parent.kind {
                case .sequence:
                    guard parent.children.count >= 2 else {
                        return nil
                    }
                    return Role(
                        owner: .sequence(nodeID: currentID),
                        path: Array(leaf.choicePath.dropFirst(parent.choicePath.count + 1)),
                        contexts: contexts,
                        metadata: metadata
                    )
                case let .pick(pickMetadata):
                    if hasVisitedPick == false {
                        hasVisitedPick = true
                        if contexts.contains(.zip) {
                            nearestPickRole = Role(
                                owner: .pick(fingerprint: pickMetadata.fingerprint),
                                path: Array(leaf.choicePath.dropFirst(parent.choicePath.count)),
                                contexts: contexts,
                                metadata: metadata
                            )
                        }
                    }
                    contexts.append(.pick(fingerprint: pickMetadata.fingerprint))
                case let .bind(metadata):
                    contexts.append(.bind(fingerprint: metadata.fingerprint))
                case .zip:
                    contexts.append(.zip)
                case .chooseBits, .just:
                    return nil
            }
            parentID = parent.parent
        }
        return nearestPickRole
    }

    /// Omits current values so a field remains a role even when other fields or occurrences differ.
    private struct Role: Hashable {
        let owner: Owner
        let path: ChoicePath
        let contexts: [Context]
        let typeTag: TypeTag
        let validRange: ClosedRange<UInt64>?
        let isRangeExplicit: Bool
        let payload: TypeTagPayload?

        init(owner: Owner, path: ChoicePath, contexts: [Context], metadata: ChooseBitsMetadata) {
            self.owner = owner
            self.path = path
            self.contexts = contexts
            typeTag = metadata.typeTag
            validRange = metadata.validRange
            isRangeExplicit = metadata.isRangeExplicit
            payload = metadata.typeTagPayload
        }
    }

    /// Keeps collection instances separate while allowing a pick site's generator identity to recur at different tree positions.
    private enum Owner: Hashable {
        case sequence(nodeID: Int)
        case pick(fingerprint: UInt64)
    }

    /// Supplements positional paths with generator fingerprints and zip context, since resize wrappers also emit group-child steps without a zip node.
    private enum Context: Hashable {
        case zip
        case pick(fingerprint: UInt64)
        case bind(fingerprint: UInt64)
    }
}
