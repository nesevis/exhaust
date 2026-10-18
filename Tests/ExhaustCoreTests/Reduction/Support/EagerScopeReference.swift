@testable import ExhaustCore

/// Retains the pre-cursor enumeration algorithms as independent references for stream order and scope payloads.
///
/// Production queries must not call these eager builders. Differential tests compare scope discovery, incremental suppression, fill eligibility, and stable candidate order against the scope sources and cursors.
enum EagerScopeReference {
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
}

/// Materializes replacement scopes in discovery order for assertions about their identities and sizes.
func replacementScopes(graph: ChoiceGraph, previousGraph: ChoiceGraph? = nil) -> [ReplacementScope] {
    let source = ReplacementSource(graph: graph, previousGraph: previousGraph, order: .discovery)
    var scopes: [ReplacementScope] = []
    while let priced = source.nextScope() {
        switch priced.encoderScope {
            case let .branchPivot(scope):
                scopes.append(.branchPivot(pickNodeID: scope.pickNodeID, targetBranchID: scope.targetBranchID))
            case let .substitution(.selfSimilar(targetNodeID, donorNodeID)):
                scopes.append(.selfSimilar(targetNodeID: targetNodeID, donorNodeID: donorNodeID, sizeDelta: priced.priority.structuralBenefit))
            case let .substitution(.descendantPromotion(ancestorPickNodeID, descendantPickNodeID)):
                scopes.append(.descendantPromotion(ancestorPickNodeID: ancestorPickNodeID, descendantPickNodeID: descendantPickNodeID, sizeDelta: priced.priority.structuralBenefit))
            default:
                preconditionFailure("A replacement source must yield a substitution or branch pivot")
        }
    }
    return scopes
}

// MARK: - Relaxation References

extension EagerScopeReference {
    /// Materializes every structural perturbation and sorts by length, as an independent oracle for the relax cursor's bounded splice ranking.
    static func relaxCandidates(sequence: ChoiceSequence, graph: ChoiceGraph) -> [ChoiceSequence] {
        var candidates: [ChoiceSequence] = []
        for scope in replacementScopes(graph: graph) {
            switch scope {
                case let .branchPivot(pickNodeID, targetBranchID):
                    if let candidate = PivotCandidates.branchPivotCandidate(
                        pickNodeID: pickNodeID,
                        targetBranchID: targetBranchID,
                        sequence: sequence,
                        graph: graph
                    ) {
                        candidates.append(candidate)
                    }
                case let .selfSimilar(targetNodeID, donorNodeID, _),
                     let .descendantPromotion(targetNodeID, donorNodeID, _):
                    guard let targetRange = graph.nodes[targetNodeID].positionRange,
                          let donorRange = graph.nodes[donorNodeID].positionRange
                    else {
                        continue
                    }
                    let expanded = PivotCandidates.expandDepthZeroLeaves(
                        Array(sequence[donorRange]),
                        donorNodeID: donorNodeID,
                        donorRangeStart: donorRange.lowerBound,
                        graph: graph
                    )
                    var candidate = sequence
                    candidate.replaceSubrange(targetRange, with: expanded)
                    if candidate != sequence {
                        candidates.append(candidate)
                    }
            }
        }
        return candidates.stablySorted { $0.count < $1.count }
    }

    /// Materializes every improving fill of every eager pivot scope, as an independent oracle for fill eligibility and stable length ordering.
    static func improvingPivotCandidates(sequence: ChoiceSequence, graph: ChoiceGraph) -> [ChoiceSequence] {
        var candidates: [ChoiceSequence] = []
        for scope in replacementScopes(graph: graph) {
            guard case let .branchPivot(pickNodeID, targetBranchID) = scope,
                  let recorded = PivotCandidates.branchPivotCandidate(pickNodeID: pickNodeID, targetBranchID: targetBranchID, fill: .recorded, sequence: sequence, graph: graph),
                  recorded.count <= sequence.count
            else {
                continue
            }
            let isShorter = recorded.count < sequence.count
            if isShorter || recorded.shortLexPrecedes(sequence) {
                candidates.append(recorded)
                if let farthest = PivotCandidates.branchPivotCandidate(pickNodeID: pickNodeID, targetBranchID: targetBranchID, fill: .farthestFromTarget, sequence: sequence, graph: graph),
                   isShorter || farthest.shortLexPrecedes(sequence)
                {
                    candidates.append(farthest)
                }
            }
            if let transplanted = PivotCandidates.branchPivotCandidate(pickNodeID: pickNodeID, targetBranchID: targetBranchID, fill: .transplanted, sequence: sequence, graph: graph),
               isShorter || transplanted.shortLexPrecedes(sequence)
            {
                candidates.append(transplanted)
            }
        }
        return candidates.stablySorted { $0.count < $1.count }
    }
}

// MARK: - Stable Sorting

extension Array {
    /// Breaks ties by original index, so oracles do not depend on the standard library's unspecified sort stability.
    func stablySorted(by areInIncreasingOrder: (Element, Element) -> Bool) -> [Element] {
        enumerated().sorted { first, second in
            if areInIncreasingOrder(first.element, second.element) {
                return true
            }
            if areInIncreasingOrder(second.element, first.element) {
                return false
            }
            return first.offset < second.offset
        }.map(\.element)
    }
}
