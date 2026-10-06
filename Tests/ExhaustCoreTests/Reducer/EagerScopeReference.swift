@testable import ExhaustCore

/// Retains the pre-cursor enumeration algorithms as independent references for stream order and scope payloads.
///
/// Production queries must not call these eager builders. Differential tests cover stable priority ties, zero-size replacements, incremental suppression, and migration extents while the generated implementations retain only domain and cursor state.
enum EagerScopeReference {
    static func replacementCandidates(
        graph: ChoiceGraph,
        previousGraph: ChoiceGraph? = nil
    ) -> [GraphTransformation] {
        var results: [GraphTransformation] = []

        for scope in replacementScopes(graph: graph, previousGraph: previousGraph) {
            let structuralYield: Int = switch scope {
                case let .selfSimilar(_, _, sizeDelta):
                    max(0, sizeDelta)
                case let .branchPivot(pickNodeID, _):
                    graph.nodes[pickNodeID].positionRange?.count ?? 0
                case let .descendantPromotion(_, _, sizeDelta):
                    sizeDelta
            }
            results.append(GraphTransformation(
                operation: .replace(scope),
                priority: DispatchPriority(
                    structuralBenefit: structuralYield,
                    valueBenefit: 0,
                    reductionMagnitude: 0,
                    estimatedCost: 1
                )
            ))
        }

        results.sort { $0.priority > $1.priority }
        return results
    }

    static func replacementScopes(
        graph: ChoiceGraph,
        previousGraph: ChoiceGraph? = nil
    ) -> [ReplacementScope] {
        var scopes: [ReplacementScope] = []

        let unchangedFingerprints: Set<UInt64> = computeUnchangedFingerprints(
            graph: graph,
            previousGraph: previousGraph
        )

        // Self-similar substitution: for each group of picks with the same fingerprint, generate one scope per ordered pair where the target is larger than the donor (positive size delta), plus one scope per zero-delta pair.
        for (fingerprint, group) in graph.selfSimilarityGroups {
            guard group.count >= 2 else {
                continue
            }
            if unchangedFingerprints.contains(fingerprint) {
                continue
            }

            var indexA = 0
            while indexA < group.count {
                let nodeA = group[indexA]
                let sizeA = graph.nodes[nodeA].positionRange?.count ?? 0
                var indexB = indexA + 1
                while indexB < group.count {
                    let nodeB = group[indexB]
                    let sizeB = graph.nodes[nodeB].positionRange?.count ?? 0
                    let sizeDelta = sizeA - sizeB
                    if sizeDelta > 0 {
                        scopes.append(.selfSimilar(
                            targetNodeID: nodeA,
                            donorNodeID: nodeB,
                            sizeDelta: sizeDelta
                        ))
                    } else if sizeDelta < 0 {
                        scopes.append(.selfSimilar(
                            targetNodeID: nodeB,
                            donorNodeID: nodeA,
                            sizeDelta: -sizeDelta
                        ))
                    } else {
                        scopes.append(.selfSimilar(
                            targetNodeID: nodeA,
                            donorNodeID: nodeB,
                            sizeDelta: 0
                        ))
                    }
                    indexB += 1
                }
                indexA += 1
            }
        }

        // Branch pivot: one scope per (pick node, alternative branch). The source iterates over branches; the encoder is single-shot per scope. The leaf-count gate is applied here — alternatives with more `.choice` leaves than the selected branch are filtered out because they almost always fail the shortlex check and dropping them avoids paying the materialization cost.
        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard case let .pick(metadata) = node.kind else {
                continue
            }
            guard metadata.branchCount >= 2 else {
                continue
            }
            guard node.children.count == Int(metadata.branchCount) else {
                continue
            }

            let selectedLeafCount = leafCount(in: metadata.branchElements[metadata.selectedChildIndex])
            let excludedTargets = graph.excludedPivotTargets(for: metadata)

            for index in 0 ..< Int(metadata.branchCount) {
                let branchID = UInt64(index)
                guard branchID != metadata.selectedID else {
                    continue
                }
                // Do not restore a constant arm whose value has an exposed sibling representation.
                guard excludedTargets.contains(branchID) == false else {
                    continue
                }

                let candidateLeafCount = leafCount(in: metadata.branchElements[index])
                guard candidateLeafCount <= selectedLeafCount else {
                    continue
                }

                scopes.append(.branchPivot(
                    pickNodeID: nodeID,
                    targetBranchID: branchID
                ))
            }
        }

        // Descendant promotion: for each pick node, check group members that are containment descendants with a smaller subtree.
        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard case let .pick(ancestorMetadata) = node.kind else {
                continue
            }
            guard let ancestorRange = node.positionRange else {
                continue
            }
            if unchangedFingerprints.contains(ancestorMetadata.fingerprint) {
                continue
            }
            guard let group = graph.selfSimilarityGroups[ancestorMetadata.fingerprint] else {
                continue
            }
            for descendantID in group {
                guard descendantID != nodeID else {
                    continue
                }
                guard let descendantRange = graph.nodes[descendantID].positionRange else {
                    continue
                }
                let sizeDelta = ancestorRange.count - descendantRange.count
                guard sizeDelta > 0 else {
                    continue
                }
                let reachable = DependencyReachability.isReachable(from: nodeID, to: descendantID, adjacency: graph.dependencyAdjacency)
                    || isContainmentDescendant(descendantID, of: nodeID, graph: graph)
                guard reachable else {
                    continue
                }
                scopes.append(.descendantPromotion(
                    ancestorPickNodeID: nodeID,
                    descendantPickNodeID: descendantID,
                    sizeDelta: sizeDelta
                ))
            }
        }

        return scopes
    }

    // MARK: - Incremental Comparison

    /// Returns the set of fingerprints whose self-similarity groups are unchanged between `previousGraph` and `graph`.
    ///
    /// A group is unchanged when it has the same member count and the same sorted multiset of subtree sizes (position range counts). Unchanged groups produce identical replacement scopes, so mid-cycle rebuilds can skip them.
    private static func computeUnchangedFingerprints(
        graph: ChoiceGraph,
        previousGraph: ChoiceGraph?
    ) -> Set<UInt64> {
        guard let previousGraph else {
            return []
        }
        var unchanged = Set<UInt64>()
        for (fingerprint, newGroup) in graph.selfSimilarityGroups {
            guard let oldGroup = previousGraph.selfSimilarityGroups[fingerprint] else {
                continue
            }
            guard oldGroup.count == newGroup.count else {
                continue
            }
            let oldSizes = oldGroup.map { previousGraph.nodes[$0].positionRange?.count ?? 0 }.sorted()
            let newSizes = newGroup.map { graph.nodes[$0].positionRange?.count ?? 0 }.sorted()
            if oldSizes == newSizes {
                unchanged.insert(fingerprint)
            }
        }
        return unchanged
    }

    // MARK: - Private Helpers

    /// Counts `.choice` leaves reachable from a choice tree subtree. Used by the leaf-count gate in branch pivot scope construction.
    private static func leafCount(in tree: ChoiceTree) -> Int {
        switch tree {
            case .choice:
                1
            case .just,
                 .getSize: 0
            case let .sequence(elements, _):
                elements.reduce(0) { $0 + leafCount(in: $1) }
            case let .branch(branch):
                leafCount(in: branch.choice)
            case let .group(children, _, _):
                children.reduce(0) { $0 + leafCount(in: $1) }
            case let .resize(_, choices):
                choices.reduce(0) { $0 + leafCount(in: $1) }
            case let .bind(_, inner, bound):
                leafCount(in: inner) + leafCount(in: bound)
        }
    }

    /// Checks whether `descendant` is reachable from `ancestor` via containment edges (parent-child chain).
    private static func isContainmentDescendant(
        _ descendant: Int,
        of ancestor: Int,
        graph: ChoiceGraph
    ) -> Bool {
        var current = descendant
        while let parentID = graph.nodes[current].parent {
            if parentID == ancestor {
                return true
            }
            current = parentID
        }
        return false
    }

    static func migrationCandidates(graph: ChoiceGraph) -> [GraphTransformation] {
        var entries: [(scope: MigrationScope, yield: Int)] = []

        // Find all sequence node pairs where source is earlier than receiver.
        // Lengths use UInt64 throughout to match the framework's length-generator type.
        var sequenceNodes: [(nodeID: Int, positionRange: ClosedRange<Int>, elementCount: UInt64, maxLength: UInt64)] = []
        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard case let .sequence(metadata) = node.kind else {
                continue
            }
            guard let range = node.positionRange else {
                continue
            }
            let maxLength = metadata.lengthConstraint?.upperBound ?? UInt64.max
            sequenceNodes.append((
                nodeID: nodeID,
                positionRange: range,
                elementCount: UInt64(metadata.elementCount),
                maxLength: maxLength
            ))
        }
        sequenceNodes.sort { $0.positionRange.lowerBound < $1.positionRange.lowerBound }

        // For each pair (source earlier, receiver later), check independence and capacity.
        for sourceIndex in 0 ..< sequenceNodes.count {
            let source = sequenceNodes[sourceIndex]
            guard source.elementCount > 0 else {
                continue
            }

            for receiverIndex in (sourceIndex + 1) ..< sequenceNodes.count {
                let receiver = sequenceNodes[receiverIndex]
                guard receiver.elementCount < receiver.maxLength else {
                    continue
                }
                guard graph.areIndependent(source.nodeID, receiver.nodeID) else {
                    continue
                }
                // Reject containment relationships.
                guard source.positionRange.contains(receiver.positionRange.lowerBound) == false,
                      receiver.positionRange.contains(source.positionRange.lowerBound) == false
                else {
                    continue
                }

                // Collect source's element node IDs and full extents.
                // Use the sequence's stored child extents so transparent wrapper markers (getSize-bind, transform-bind) move with their value entries — otherwise migration leaves orphan markers and the materializer rejects the candidate.
                let sourceNode = graph.nodes[source.nodeID]
                guard case let .sequence(sourceMetadata) = sourceNode.kind else {
                    continue
                }
                guard sourceMetadata.childPositionRanges.count == sourceNode.children.count else {
                    continue
                }
                var elementNodeIDs: [Int] = []
                var elementRanges: [ClosedRange<Int>] = []
                for (childIndex, childID) in sourceNode.children.enumerated() {
                    guard graph.nodes[childID].positionRange != nil else {
                        continue
                    }
                    elementNodeIDs.append(childID)
                    elementRanges.append(sourceMetadata.childPositionRanges[childIndex])
                }

                guard elementNodeIDs.isEmpty == false else {
                    continue
                }

                // Yield: the position count of the elements being moved.
                // Moving them shortens the source (improves shortlex at earlier positions).
                let totalYield = elementRanges.reduce(0) { $0 + $1.count }

                // Determine whether this is a full migration (all source elements moved).
                let isFullMigration = elementNodeIDs.count == sourceNode.children.count
                let sourceParentSequenceNodeID: Int? = {
                    guard isFullMigration,
                          let parentID = sourceNode.parent,
                          case .sequence = graph.nodes[parentID].kind
                    else {
                        return nil
                    }
                    return parentID
                }()

                let scope = MigrationScope(
                    sourceSequenceNodeID: source.nodeID,
                    receiverSequenceNodeID: receiver.nodeID,
                    elementNodeIDs: elementNodeIDs,
                    elementPositionRanges: elementRanges,
                    receiverPositionRange: receiver.positionRange,
                    sourceParentSequenceNodeID: sourceParentSequenceNodeID
                )

                entries.append((scope: scope, yield: totalYield))
            }
        }

        // Sort by yield descending.
        entries.sort { $0.yield > $1.yield }

        return entries.map { entry in
            GraphTransformation(
                operation: .migrate(entry.scope),
                priority: DispatchPriority(
                    structuralBenefit: entry.yield,
                    valueBenefit: 0,
                    reductionMagnitude: 0,
                    estimatedCost: 1
                )
            )
        }
    }
}

/// Materializes production streams only for tests that inspect the complete scope set.
extension ReplacementQuery {
    /// Materializes the discovery stream for assertions inspecting complete replacement scopes.
    ///
    /// When `previousGraph` is present, unchanged self-similarity families are suppressed while pivots remain available.
    static func build(graph: ChoiceGraph, previousGraph: ChoiceGraph? = nil) -> [ReplacementScope] {
        var cursor = discoveryCursor(graph: graph, previousGraph: previousGraph)
        var scopes: [ReplacementScope] = []
        while let transformation = cursor.next() {
            guard case let .replace(scope) = transformation.operation else {
                continue
            }
            scopes.append(scope)
        }
        return scopes
    }
}
