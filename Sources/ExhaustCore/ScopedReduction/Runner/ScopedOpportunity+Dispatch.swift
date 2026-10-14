//
//  ScopedOpportunity+Dispatch.swift
//  Exhaust
//

// MARK: - Dispatch Properties

extension ScopedOpportunity {
    /// The encoder that runs this opportunity, by name, for eligibility checks that need no encoder value.
    var encoderName: EncoderName {
        switch self {
            case .boundValue:
                .boundValueSearch
            case .boundExchange:
                .boundExchange
            case .bindPivot:
                .bindPivot
            case .depthCollapse:
                .depthCollapse
            case .laneCollapse:
                .laneCollapse
            case .valueSearch(.integer):
                .valueSearch
            case .valueSearch(.float):
                .floatSearch
            case .redistribution:
                .redistribution
            case .lockstep:
                .lockstep
            case .relation:
                .relationSearch
            case .stagedJoint:
                .stagedJointSearch
            case .removal:
                .deletion
            case .substitution:
                .substitution
            case .branchPivot:
                .branchPivot
            case .migration:
                .migration
            case .swap:
                .siblingSwap
            case .reorder:
                .numericReorder
        }
    }

    /// Whether the encoder lifts its probes through a materialization, and so needs the generator in hand. Relax round exploitation has none to give and skips these.
    var requiresGenerator: Bool {
        switch self {
            case .boundValue, .bindPivot, .boundExchange:
                true
            case .depthCollapse, .laneCollapse, .valueSearch, .redistribution, .lockstep, .relation, .stagedJoint,
                 .removal, .substitution, .branchPivot, .migration, .swap, .reorder:
                false
        }
    }

    /// Whether the operation changes the generator's active execution path. Only replacement does, so on a graph stripped of unselected branches it needs them restored first.
    var isPathChanging: Bool {
        switch self {
            case .substitution, .branchPivot:
                true
            case .boundValue, .bindPivot, .boundExchange, .depthCollapse, .laneCollapse, .valueSearch, .redistribution,
                 .lockstep, .relation, .stagedJoint, .removal, .migration, .swap, .reorder:
                false
        }
    }

    /// Whether the operation's target nodes still exist and satisfy its preconditions in `graph`.
    func isValid(in graph: ChoiceGraph) -> Bool {
        switch self {
            case let .removal(.elements(scope)):
                return scope.targets.allSatisfy { target in
                    Self.sequenceCanShrink(target.sequenceNodeID, in: graph)
                }
            case let .removal(.coveringAligned(scope)):
                return scope.siblings.allSatisfy { sibling in
                    Self.sequenceCanShrink(sibling.sequenceNodeID, in: graph)
                }
            case let .removal(.window(scope)):
                return Self.sequenceCanShrink(scope.sequenceNodeID, in: graph)
            case let .substitution(.selfSimilar(targetNodeID, donorNodeID)):
                return targetNodeID < graph.nodes.count
                    && graph.nodes[targetNodeID].positionRange != nil
                    && donorNodeID < graph.nodes.count
                    && graph.nodes[donorNodeID].positionRange != nil
            case let .branchPivot(scope):
                return scope.pickNodeID < graph.nodes.count
                    && graph.nodes[scope.pickNodeID].positionRange != nil
            case let .substitution(.descendantPromotion(ancestorPickNodeID, descendantPickNodeID)):
                return ancestorPickNodeID < graph.nodes.count
                    && graph.nodes[ancestorPickNodeID].positionRange != nil
                    && descendantPickNodeID < graph.nodes.count
                    && graph.nodes[descendantPickNodeID].positionRange != nil
            case let .swap(scope):
                return scope.parentNodeID < graph.nodes.count
                    && graph.nodes[scope.parentNodeID].positionRange != nil
            case let .migration(scope):
                let donorSequenceNodeID = scope.sourceParentSequenceNodeID ?? scope.sourceSequenceNodeID
                guard Self.sequenceCanShrink(donorSequenceNodeID, in: graph) else {
                    return false
                }
                return scope.receiverSequenceNodeID < graph.nodes.count
                    && graph.nodes[scope.receiverSequenceNodeID].positionRange != nil
            case let .bindPivot(scope):
                return scope.bindNodeID < graph.nodes.count
                    && graph.nodes[scope.bindNodeID].positionRange != nil
                    && scope.pickNodeID < graph.nodes.count
                    && graph.nodes[scope.pickNodeID].positionRange != nil
            case .boundValue, .boundExchange, .depthCollapse, .laneCollapse, .valueSearch, .redistribution, .lockstep,
                 .relation, .stagedJoint, .reorder:
                return true
        }
    }

    // MARK: - Rejection Keys

    /// Per-scope discriminator for the scope rejection cache. Branch pivot uses the target branch so that rejecting one branch at a pick does not block another. Bind pivot mixes the pick's node ID in as well, because its affected set is the bind alone and one bind inner can hold several picks with the same branch identifiers. Centered and symmetric windows have separate discriminators so rejecting a full-window removal does not block their smaller probes or one another. Zero otherwise.
    var scopeSubDiscriminator: UInt64 {
        if case let .removal(.window(scope)) = self {
            switch scope.growth {
                case .rightward:
                    return 0
                case .outward:
                    return 0xC37E_2ED0_0000_0001
                case .symmetric:
                    return 0xC37E_2ED0_0000_0002
            }
        }
        if case let .branchPivot(scope) = self {
            return scope.targetBranchID
        }
        if case let .bindPivot(scope) = self {
            return scope.targetBranchID ^ (UInt64(scope.pickNodeID) &* 0x9E37_79B9_7F4A_7C15)
        }
        return 0
    }

    /// Invokes `body` for each node whose position range the operation affects, for the scope rejection cache's position-scoped hashes.
    ///
    /// Returns `false` for searches, whose affected set is not fixed by the scope, and for aligned removal, whose rows vary. Bind pivot is the exception among minimization scopes: its candidate is a function of the bind's current entries, and the bind's range covers the pick, so the bind alone is its affected set. Reporting the pick as well would cancel its positions out of the hash.
    func forEachAffectedNodeID(_ body: (Int) -> Void) -> Bool {
        switch self {
            case let .bindPivot(scope):
                body(scope.bindNodeID)
            case let .removal(.elements(elementScope)):
                for target in elementScope.targets {
                    for nodeID in target.elementNodeIDs {
                        body(nodeID)
                    }
                }
            case .removal(.coveringAligned):
                return false
            case let .removal(.window(windowScope)):
                for nodeID in windowScope.elementNodeIDs {
                    body(nodeID)
                }
            case let .substitution(.selfSimilar(targetNodeID, donorNodeID)):
                body(targetNodeID)
                body(donorNodeID)
            case let .branchPivot(scope):
                body(scope.pickNodeID)
            case let .substitution(.descendantPromotion(ancestorPickNodeID, descendantPickNodeID)):
                body(ancestorPickNodeID)
                body(descendantPickNodeID)
            case let .swap(scope):
                for group in scope.swappableGroups {
                    for nodeID in group {
                        body(nodeID)
                    }
                }
            case let .migration(scope):
                for nodeID in scope.elementNodeIDs {
                    body(nodeID)
                }
                body(scope.receiverSequenceNodeID)
            case .boundValue, .boundExchange, .depthCollapse, .laneCollapse, .valueSearch, .redistribution, .lockstep,
                 .relation, .stagedJoint, .reorder:
                return false
        }
        return true
    }

    // MARK: - Helpers

    /// Whether the node is a sequence that still holds more elements than its minimum length.
    private static func sequenceCanShrink(_ sequenceNodeID: Int, in graph: ChoiceGraph) -> Bool {
        guard sequenceNodeID < graph.nodes.count,
              case let .sequence(metadata) = graph.nodes[sequenceNodeID].kind
        else {
            return false
        }
        return UInt64(metadata.elementCount) > (metadata.lengthConstraint?.lowerBound ?? 0)
    }
}
