//
//  ChoiceGraph+Scopes.swift
//  Exhaust
//

// MARK: - Removal Scope Queries

extension ChoiceGraph {

    /// Computes element removal scopes for all sequence nodes with deletable elements and all aligned sibling groupings.
    ///
    /// Returns both per-parent scopes (single target) and aligned scopes (multiple targets under a common zip). The ``TransformationEnumerator`` feeds these into the priority queue; scope sources handle geometric halving and window placement.
    ///
    /// - Returns: One scope per sequence node with deletable elements, plus one per aligned sibling subset (size >= 2) per zip node.
    func elementRemovalScopes() -> [ElementRemovalScope] {
        var scopes: [ElementRemovalScope] = []

        // Per-parent scopes: one target per sequence.
        scopes.append(contentsOf: perParentElementScopes())

        // Aligned scopes: multiple targets across sibling sequences under zip nodes.
        scopes.append(contentsOf: alignedElementScopes())

        return scopes
    }

    // MARK: - Per-Parent Element Scopes

    /// Computes per-parent removal scopes for all sequence nodes with deletable elements.
    ///
    /// Groups deletable elements by their parent sequence node. Each scope contains a single ``SequenceRemovalTarget`` with elements in position order.
    private func perParentElementScopes() -> [ElementRemovalScope] {
        var parentGroups: [Int: [Int]] = [:]

        for node in nodes {
            guard node.positionRange != nil else { continue }
            guard let parentID = node.parent else { continue }
            guard case let .sequence(metadata) = nodes[parentID].kind else { continue }
            let minLength = metadata.lengthConstraint?.lowerBound ?? 0
            guard UInt64(metadata.elementCount) > minLength else { continue }
            parentGroups[parentID, default: []].append(node.id)
        }

        return parentGroups.sorted(by: { $0.key < $1.key }).map { parentID, elementNodeIDs in
            let sortedElements = elementNodeIDs.sorted { nodeA, nodeB in
                let rangeA = nodes[nodeA].positionRange?.lowerBound ?? 0
                let rangeB = nodes[nodeB].positionRange?.lowerBound ?? 0
                return rangeA < rangeB
            }
            let maxElementYield = sortedElements.reduce(0) { maxSoFar, nodeID in
                max(maxSoFar, nodes[nodeID].positionRange?.count ?? 0)
            }
            let deletable: Int
            if case let .sequence(metadata) = nodes[parentID].kind {
                let minLength = Int(metadata.lengthConstraint?.lowerBound ?? 0)
                deletable = metadata.elementCount - minLength
            } else {
                deletable = sortedElements.count
            }
            return ElementRemovalScope(
                targets: [SequenceRemovalTarget(
                    sequenceNodeID: parentID,
                    elementNodeIDs: sortedElements
                )],
                maxBatch: deletable,
                maxElementYield: maxElementYield
            )
        }
    }

    // MARK: - Aligned Element Scopes

    /// Intermediate type used during aligned scope computation.
    private struct SiblingInfo {
        let sequenceNodeID: Int
        let elementNodeIDs: [Int]
        let deletableCount: Int
    }

    /// Computes aligned removal scopes for all zip nodes with multiple sequence children, including partial sibling subsets.
    ///
    /// Looks through transparent wrappers (groups, structurally-constant binds) beneath each zip child to find the underlying sequence node. Generates scopes for all subsets of siblings of size two or more.
    private func alignedElementScopes() -> [ElementRemovalScope] {
        var scopes: [ElementRemovalScope] = []
        for node in nodes {
            guard case .zip = node.kind else { continue }
            guard node.positionRange != nil else { continue }

            let allSequenceChildren = node.children.compactMap { childID -> SiblingInfo? in
                guard let sequenceNodeID = findSequenceBeneath(childID) else { return nil }
                let sequenceNode = nodes[sequenceNodeID]
                guard case let .sequence(metadata) = sequenceNode.kind else { return nil }
                let minLength = Int(metadata.lengthConstraint?.lowerBound ?? 0)
                let deletable = metadata.elementCount - minLength
                guard deletable > 0 else { return nil }
                return SiblingInfo(
                    sequenceNodeID: sequenceNodeID,
                    elementNodeIDs: sequenceNode.children,
                    deletableCount: deletable
                )
            }
            guard allSequenceChildren.count >= 2 else { continue }

            let subsets = siblingSubsets(allSequenceChildren)
            for subset in subsets {
                guard subset.map(\.deletableCount).allSatisfy({ $0 > 0 }) else { continue }
                if subset.count == 2 {
                    generateAlignedCrossProductScopes(
                        subset: subset,
                        siblingIndex: 0,
                        currentIndices: [],
                        into: &scopes
                    )
                } else {
                    let elementCount = subset.map { $0.elementNodeIDs.count }.min() ?? 0
                    for elementIndex in 0 ..< elementCount {
                        var targets: [SequenceRemovalTarget] = []
                        var totalYield = 0
                        var valid = true
                        for sibling in subset {
                            guard elementIndex < sibling.elementNodeIDs.count else { valid = false; break }
                            let nodeID = sibling.elementNodeIDs[elementIndex]
                            targets.append(SequenceRemovalTarget(
                                sequenceNodeID: sibling.sequenceNodeID,
                                elementNodeIDs: [nodeID]
                            ))
                            totalYield += nodes[nodeID].positionRange?.count ?? 0
                        }
                        guard valid else { continue }
                        scopes.append(ElementRemovalScope(
                            targets: targets,
                            maxBatch: 1,
                            maxElementYield: totalYield
                        ))
                    }
                }
            }
        }
        return scopes
    }

    private func siblingSubsets(_ siblings: [SiblingInfo]) -> [[SiblingInfo]] {
        let count = siblings.count
        guard count >= 2 else { return [] }
        var subsets: [[SiblingInfo]] = []
        for size in stride(from: count, through: 2, by: -1) {
            generateCombinations(siblings, choose: size, into: &subsets)
        }
        return subsets
    }

    private func generateCombinations(
        _ source: [SiblingInfo],
        choose: Int,
        into result: inout [[SiblingInfo]]
    ) {
        let count = source.count
        guard choose >= 1, choose <= count else { return }
        var indices = Array(0 ..< choose)
        while true {
            result.append(indices.map { source[$0] })
            var position = choose - 1
            while position >= 0, indices[position] == count - choose + position {
                position -= 1
            }
            if position < 0 { break }
            indices[position] += 1
            for subsequent in (position + 1) ..< choose {
                indices[subsequent] = indices[subsequent - 1] + 1
            }
        }
    }

    /// Recursively generates all cross-product combinations of one element index per sibling and emits one ``ElementRemovalScope`` per combination.
    private func generateAlignedCrossProductScopes(
        subset: [SiblingInfo],
        siblingIndex: Int,
        currentIndices: [Int],
        into scopes: inout [ElementRemovalScope]
    ) {
        guard siblingIndex < subset.count else {
            var targets: [SequenceRemovalTarget] = []
            var totalYield = 0
            for (sibling, index) in zip(subset, currentIndices) {
                let nodeID = sibling.elementNodeIDs[index]
                targets.append(SequenceRemovalTarget(
                    sequenceNodeID: sibling.sequenceNodeID,
                    elementNodeIDs: [nodeID]
                ))
                totalYield += nodes[nodeID].positionRange?.count ?? 0
            }
            scopes.append(ElementRemovalScope(
                targets: targets,
                maxBatch: 1,
                maxElementYield: totalYield
            ))
            return
        }
        let sibling = subset[siblingIndex]
        for index in 0 ..< sibling.elementNodeIDs.count {
            generateAlignedCrossProductScopes(
                subset: subset,
                siblingIndex: siblingIndex + 1,
                currentIndices: currentIndices + [index],
                into: &scopes
            )
        }
    }

    // MARK: - Transparent Wrapper Traversal

    /// Walks through transparent wrappers (groups, structurally-constant binds) beneath a node to find the first sequence node.
    ///
    /// Returns the sequence node's ID, or nil if no sequence is found beneath the transparent chain.
    private func findSequenceBeneath(_ nodeID: Int) -> Int? {
        let node = nodes[nodeID]
        if case .sequence = node.kind {
            return nodeID
        }
        switch node.kind {
        case .zip:
            for childID in node.children {
                if let found = findSequenceBeneath(childID) {
                    return found
                }
            }
            return nil
        case let .bind(metadata):
            if metadata.isStructurallyConstant, node.children.count >= 2 {
                let boundChildID = node.children[metadata.boundChildIndex]
                return findSequenceBeneath(boundChildID)
            }
            return nil
        case .chooseBits, .pick, .just:
            return nil
        case .sequence:
            return nodeID
        }
    }

    /// Computes subtree removal scopes for compound structural nodes in the deletion antichain.
    ///
    /// Targets nodes with ``ChoiceGraphNode/positionRange`` count greater than one — bind subtrees, zip children, and other compound elements worth removing as a unit.
    ///
    /// - Returns: One scope per compound node in the deletion antichain.
    func subtreeRemovalScopes() -> [SubtreeRemovalScope] {
        deletionAntichain.compactMap { nodeID in
            guard let range = nodes[nodeID].positionRange else { return nil }
            guard range.count > 1 else { return nil }
            return SubtreeRemovalScope(nodeID: nodeID, yield: range.count)
        }
    }
}

// MARK: - Replacement Scope Queries

extension ChoiceGraph {

    /// Computes replacement scopes from self-similarity edges, pick nodes, and descendant promotion candidates.
    ///
    /// - Returns: All replacement scopes across the three sub-types.
    func replacementScopes() -> [ReplacementScope] {
        var scopes: [ReplacementScope] = []

        // Self-similar substitution: each self-similarity edge with
        // positive size delta is a candidate (nodeA is target, nodeB is donor).
        for edge in selfSimilarityEdges {
            if edge.sizeDelta > 0 {
                scopes.append(.selfSimilar(SelfSimilarReplacementScope(
                    targetNodeID: edge.nodeA,
                    donorNodeID: edge.nodeB,
                    sizeDelta: edge.sizeDelta
                )))
            } else if edge.sizeDelta < 0 {
                scopes.append(.selfSimilar(SelfSimilarReplacementScope(
                    targetNodeID: edge.nodeB,
                    donorNodeID: edge.nodeA,
                    sizeDelta: -edge.sizeDelta
                )))
            }
            // Zero-delta edges: both directions for cross-group promotion.
            if edge.sizeDelta == 0 {
                scopes.append(.selfSimilar(SelfSimilarReplacementScope(
                    targetNodeID: edge.nodeA,
                    donorNodeID: edge.nodeB,
                    sizeDelta: 0
                )))
            }
        }

        // Branch pivot: one scope per active pick node, carrying all
        // non-selected alternatives sorted simplest-first by subtree size.
        // The encoder iterates `targetBranchIDs` across probes within a
        // single scope dispatch — bundling at the pick-site level keeps
        // alternatives off the scheduler's priority queue, where lower-yield
        // pivots would otherwise be starved by higher-yield ones from other
        // pick sites.
        for node in nodes {
            guard case let .pick(metadata) = node.kind else { continue }
            guard node.positionRange != nil else { continue }
            guard metadata.branchIDs.count >= 2 else { continue }
            guard node.children.count == metadata.branchIDs.count else { continue }

            // Build (branchID, subtreeSize) pairs for non-selected branches.
            var alternatives: [(branchID: UInt64, subtreeSize: Int)] = []
            for index in 0 ..< metadata.branchIDs.count {
                let branchID = metadata.branchIDs[index]
                guard branchID != metadata.selectedID else { continue }
                let childNodeID = node.children[index]
                alternatives.append((
                    branchID: branchID,
                    subtreeSize: subtreeNodeCount(rootID: childNodeID)
                ))
            }
            alternatives.sort { $0.subtreeSize < $1.subtreeSize }

            guard alternatives.isEmpty == false else { continue }

            scopes.append(.branchPivot(BranchPivotScope(
                pickNodeID: node.id,
                siteID: metadata.siteID,
                selectedID: metadata.selectedID,
                targetBranchIDs: alternatives.map(\.branchID)
            )))
        }

        // Descendant promotion: pairs (ancestor pick, descendant pick) with
        // matching depthMaskedSiteID where the descendant's subtree is smaller.
        for node in nodes {
            guard case let .pick(ancestorMetadata) = node.kind else { continue }
            guard let ancestorRange = node.positionRange else { continue }
            for edge in selfSimilarityEdges {
                let otherID = edge.nodeA == node.id ? edge.nodeB : (edge.nodeB == node.id ? edge.nodeA : nil)
                guard let descendantID = otherID else { continue }
                guard let descendantRange = nodes[descendantID].positionRange else { continue }
                // The descendant must be reachable from the ancestor via containment.
                let reachable = reachability[node.id]?.contains(descendantID) ?? false
                    || isContainmentDescendant(descendantID, of: node.id)
                guard reachable else { continue }
                let sizeDelta = ancestorRange.count - descendantRange.count
                guard sizeDelta > 0 else { continue }
                // Avoid duplicate with self-similar scope.
                guard case let .pick(descendantMetadata) = nodes[descendantID].kind,
                      descendantMetadata.depthMaskedSiteID == ancestorMetadata.depthMaskedSiteID else {
                    continue
                }
                scopes.append(.descendantPromotion(DescendantPromotionScope(
                    ancestorPickNodeID: node.id,
                    descendantPickNodeID: descendantID,
                    sizeDelta: sizeDelta
                )))
            }
        }

        return scopes
    }

    /// Counts the total number of graph nodes in the subtree rooted at the given node.
    private func subtreeNodeCount(rootID: Int) -> Int {
        var count = 0
        var stack = [rootID]
        while let current = stack.popLast() {
            count += 1
            stack.append(contentsOf: nodes[current].children)
        }
        return count
    }

    /// Checks whether `descendant` is reachable from `ancestor` via containment edges (parent-child chain).
    private func isContainmentDescendant(_ descendant: Int, of ancestor: Int) -> Bool {
        var current = descendant
        while let parentID = nodes[current].parent {
            if parentID == ancestor { return true }
            current = parentID
        }
        return false
    }
}

// MARK: - Minimization Scope Queries

extension ChoiceGraph {

    /// Computes minimization scopes: one integer scope, one float scope, and one Kleisli fibre scope per non-constant reduction edge.
    ///
    /// - Returns: All minimization scopes, each ordered by value yield descending (bind-inner leaves with large bound subtrees first).
    func minimizationScopes() -> [MinimizationScope] {
        let innerChildToBind = buildInnerChildToBind()
        var scopes: [MinimizationScope] = []

        // Integer leaves.
        var integerLeafNodeIDs: [Int] = []
        var integerValueYields: [Int: Int] = [:]

        // Float leaves.
        var floatLeafNodeIDs: [Int] = []

        for nodeID in leafNodes {
            let node = nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind else { continue }

            let currentBitPattern = metadata.value.bitPattern64
            let targetBitPattern = metadata.value.reductionTarget(in: metadata.validRange)
            guard currentBitPattern != targetBitPattern else { continue }
            guard metadata.convergedOrigin == nil else { continue }

            if metadata.typeTag.isFloatingPoint {
                floatLeafNodeIDs.append(nodeID)
            } else {
                let valueYield = computeValueYield(
                    leafNodeID: nodeID,
                    innerChildToBind: innerChildToBind
                )
                integerLeafNodeIDs.append(nodeID)
                integerValueYields[nodeID] = valueYield
            }
        }

        // Sort integer leaves by value yield descending.
        integerLeafNodeIDs.sort { nodeA, nodeB in
            (integerValueYields[nodeA] ?? 0) > (integerValueYields[nodeB] ?? 0)
        }

        if integerLeafNodeIDs.isEmpty == false {
            let entries = integerLeafNodeIDs.map { nodeID in
                LeafEntry(
                    nodeID: nodeID,
                    mayReshapeOnAcceptance: isBindInner(
                        nodeID,
                        innerChildToBind: innerChildToBind
                    )
                )
            }
            scopes.append(.valueLeaves(ValueMinimizationScope(
                leaves: entries,
                batchZeroEligible: entries.count > 1
            )))
        }

        if floatLeafNodeIDs.isEmpty == false {
            let entries = floatLeafNodeIDs.map { nodeID in
                LeafEntry(
                    nodeID: nodeID,
                    mayReshapeOnAcceptance: isBindInner(
                        nodeID,
                        innerChildToBind: innerChildToBind
                    )
                )
            }
            scopes.append(.floatLeaves(FloatMinimizationScope(leaves: entries)))
        }

        // Kleisli fibre: one scope per reduction edge. Matches the CDG's
        // ``ChoiceDependencyGraph/reductionEdges()`` behaviour, which deliberately does
        // NOT filter on ``isStructurallyConstant``: a structurally constant bind (no
        // nested binds/picks) can still carry domain-dependent values whose ranges
        // shift with the upstream value (Coupling's `int(in: 0...n).array(length: 2 ...
        // max(2, n+1))` is the canonical example — the bound subtree contains only
        // plain choices, but their ranges depend on `n`). The composition's downstream
        // encoder finds these via the lift's fibre coverage.
        for edge in reductionEdges {
            guard nodes[edge.upstreamNodeID].positionRange != nil else { continue }
            let downstreamNodeIDs = collectDescendantLeaves(from: edge.downstreamNodeID)
            let boundSubtreeSize = nodes[edge.downstreamNodeID].positionRange?.count ?? 0
            scopes.append(.kleisliFibre(KleisliFibreScope(
                bindNodeID: findParentBind(of: edge.upstreamNodeID) ?? edge.upstreamNodeID,
                upstreamLeafNodeID: edge.upstreamNodeID,
                downstreamNodeIDs: downstreamNodeIDs,
                boundSubtreeSize: boundSubtreeSize
            )))
        }

        return scopes
    }

    // MARK: - Minimization Helpers

    /// Builds an index from inner-child node ID to its controlling bind node ID.
    private func buildInnerChildToBind() -> [Int: Int] {
        var index: [Int: Int] = [:]
        for node in nodes {
            guard case let .bind(metadata) = node.kind else { continue }
            guard node.children.count >= 2 else { continue }
            let innerChildID = node.children[metadata.innerChildIndex]
            index[innerChildID] = node.id
        }
        return index
    }

    /// Computes value yield for a leaf: the bound subtree size if this leaf is a bind-inner, otherwise zero.
    ///
    /// Bind-inner leaves are sorted first in the integer scope because their mutations have the largest downstream effect — changing the inner value rebuilds the entire bound subtree. Independent of ``BindMetadata/isStructurallyConstant``: a "structurally constant" bind in the no-nested-binds-or-picks sense (e.g. Coupling's `int(in: 0...n).array(length: 2 ... max(2, n+1))`) can still carry domain-dependent values whose ranges and lengths shift with the inner, so changing the inner is still a high-yield mutation.
    private func computeValueYield(
        leafNodeID: Int,
        innerChildToBind: [Int: Int]
    ) -> Int {
        guard let bindNodeID = innerChildToBind[leafNodeID] else { return 0 }
        guard case let .bind(metadata) = nodes[bindNodeID].kind else { return 0 }
        guard nodes[bindNodeID].children.count >= 2 else { return 0 }
        let boundChildID = nodes[bindNodeID].children[metadata.boundChildIndex]
        return nodes[boundChildID].positionRange?.count ?? 0
    }

    /// Returns true when a leaf is the inner child of a bind. Any bind-inner mutation must route through ``ChoiceGraph/applyBindReshape(forLeaf:freshTree:into:)`` (not the value-only fast path) because the materialiser may produce a tree with a different bound-subtree shape — different array length, different value ranges, different content — even when the bind has no *nested* binds or picks.
    ///
    /// The previous predicate filtered on ``BindMetadata/isStructurallyConstant`` and missed Coupling's `int(in: 0...n).array(length: 2 ... max(2, n+1))`: the bound contains only plain choices (so `isStructurallyConstant == true`), but its length and element validRanges depend on `n`, so changing `n` changes the live tree's shape. The value-only fast path then left the graph holding the old bound subtree's nodes at positions that no longer corresponded to value entries in the live sequence, producing the position drift documented in `ExhaustDocs/graph-reducer-position-drift-bug.md`.
    ///
    /// Always treating bind-inner leaves as `mayReshape: true` is correct and simple. The cost is that the rare workloads where the bound subtree is genuinely shape-and-content-stable pay extra splice work; in exchange the splice path is the only place that handles bind-inner mutations and the contract is uniform.
    func isBindInner(
        _ leafNodeID: Int,
        innerChildToBind: [Int: Int]
    ) -> Bool {
        innerChildToBind[leafNodeID] != nil
    }

    /// Wraps a leaf node ID in a ``LeafEntry`` with the bind-inner reshape marker populated from the supplied index.
    func makeLeafEntry(
        _ nodeID: Int,
        innerChildToBind: [Int: Int]
    ) -> LeafEntry {
        LeafEntry(
            nodeID: nodeID,
            mayReshapeOnAcceptance: isBindInner(
                nodeID,
                innerChildToBind: innerChildToBind
            )
        )
    }

    /// Collects all leaf node IDs (chooseBits with non-nil position range) within the subtree rooted at the given node.
    private func collectDescendantLeaves(from rootNodeID: Int) -> [Int] {
        var result: [Int] = []
        var stack = [rootNodeID]
        while let current = stack.popLast() {
            let node = nodes[current]
            if case .chooseBits = node.kind, node.positionRange != nil {
                result.append(current)
            }
            stack.append(contentsOf: node.children)
        }
        return result
    }

    /// Finds the parent bind node of a given node, or nil.
    private func findParentBind(of nodeID: Int) -> Int? {
        var current = nodeID
        while let parentID = nodes[current].parent {
            if case .bind = nodes[parentID].kind {
                return parentID
            }
            current = parentID
        }
        return nil
    }
}

// MARK: - Exchange Scope Queries

extension ChoiceGraph {

    /// Computes exchange scopes from type-compatibility edges and leaf groupings.
    ///
    /// Redistribution pairs any two type-compatible leaves where one is not at its reduction target. The source is zeroed and the receiver absorbs the delta. Both intra-sequence and inter-sequence pairs are included — any type-compatible pair connected by a type-compatibility edge is a candidate.
    ///
    /// - Returns: Redistribution scope (if pairs exist) and tandem scope (if same-typed leaf groups with at least two members exist).
    func exchangeScopes() -> [ExchangeScope] {
        let innerChildToBind = buildInnerChildToBind()
        var scopes: [ExchangeScope] = []

        // Redistribution: pair any two type-compatible leaves where at least
        // one is not at its reduction target. The source (farther from target)
        // gets zeroed; the receiver absorbs the delta.
        var pairs: [RedistributionPair] = []
        for edge in typeCompatibilityEdges {
            guard case let .chooseBits(metadataA) = nodes[edge.nodeA].kind,
                  case let .chooseBits(metadataB) = nodes[edge.nodeB].kind else {
                continue
            }

            let targetA = metadataA.value.reductionTarget(in: metadataA.validRange)
            let targetB = metadataB.value.reductionTarget(in: metadataB.validRange)
            let distanceA = metadataA.value.bitPattern64 > targetA
                ? metadataA.value.bitPattern64 - targetA
                : targetA - metadataA.value.bitPattern64
            let distanceB = metadataB.value.bitPattern64 > targetB
                ? metadataB.value.bitPattern64 - targetB
                : targetB - metadataB.value.bitPattern64

            // Skip if both are already at target.
            guard distanceA > 0 || distanceB > 0 else { continue }

            // The source must be at an earlier position than the receiver
            // so that zeroing the source produces a shortlex-smaller candidate
            // (the first pairwise difference favors the candidate).
            let positionA = nodes[edge.nodeA].positionRange?.lowerBound ?? Int.max
            let positionB = nodes[edge.nodeB].positionRange?.lowerBound ?? Int.max

            // A is earlier — A can be the source (zeroed), B receives.
            if positionA < positionB, distanceA > 0 {
                pairs.append(RedistributionPair(
                    source: makeLeafEntry(edge.nodeA, innerChildToBind: innerChildToBind),
                    sink: makeLeafEntry(edge.nodeB, innerChildToBind: innerChildToBind),
                    sourceTag: metadataA.typeTag,
                    sinkTag: metadataB.typeTag
                ))
            }
            // B is earlier — B can be the source (zeroed), A receives.
            if positionB < positionA, distanceB > 0 {
                pairs.append(RedistributionPair(
                    source: makeLeafEntry(edge.nodeB, innerChildToBind: innerChildToBind),
                    sink: makeLeafEntry(edge.nodeA, innerChildToBind: innerChildToBind),
                    sourceTag: metadataB.typeTag,
                    sinkTag: metadataA.typeTag
                ))
            }
        }
        if pairs.isEmpty == false {
            scopes.append(.redistribution(RedistributionScope(pairs: pairs)))
        }

        // Tandem: group active leaves by TypeTag.
        var leafGroups: [TypeTag: [Int]] = [:]
        for nodeID in leafNodes {
            guard case let .chooseBits(metadata) = nodes[nodeID].kind else { continue }
            leafGroups[metadata.typeTag, default: []].append(nodeID)
        }
        let tandemGroups = leafGroups.compactMap { tag, leafIDs -> TandemGroup? in
            guard leafIDs.count >= 2 else { return nil }
            let entries = leafIDs.map { makeLeafEntry($0, innerChildToBind: innerChildToBind) }
            return TandemGroup(leaves: entries, typeTag: tag)
        }
        if tandemGroups.isEmpty == false {
            scopes.append(.tandem(TandemScope(groups: tandemGroups)))
        }

        return scopes
    }

}

// MARK: - Permutation Scope Queries

extension ChoiceGraph {

    /// Computes permutation scopes for zip nodes with same-shaped siblings.
    ///
    /// Groups children by structural shape derived from graph node metadata. Children with the same shape can be swapped for shortlex improvement.
    ///
    /// - Returns: One scope per zip node with at least one group of two or more same-shaped children.
    func permutationScopes() -> [PermutationScope] {
        var scopes: [PermutationScope] = []

        for node in nodes {
            guard case .zip = node.kind else { continue }
            guard node.positionRange != nil else { continue }
            guard node.children.count >= 2 else { continue }

            var shapeGroups: [NodeShapeKey: [Int]] = [:]
            for childID in node.children {
                guard nodes[childID].positionRange != nil else { continue }
                let key = nodeShapeKey(nodes[childID])
                shapeGroups[key, default: []].append(childID)
            }

            let swappableGroups = shapeGroups.values
                .filter { $0.count >= 2 }
                .sorted { groupA, groupB in
                    let positionA = nodes[groupA[0]].positionRange?.lowerBound ?? 0
                    let positionB = nodes[groupB[0]].positionRange?.lowerBound ?? 0
                    return positionA < positionB
                }

            guard swappableGroups.isEmpty == false else { continue }

            scopes.append(.siblingPermutation(SiblingPermutationScope(
                zipNodeID: node.id,
                swappableGroups: swappableGroups
            )))
        }

        return scopes
    }

    // MARK: - Shape Key

    /// Lightweight shape discriminant for grouping siblings by structural kind.
    ///
    /// Derived from graph node metadata rather than the ``ChoiceTree``. Matches the grouping logic in ``GraphSiblingSwapEncoder``.
    private enum NodeShapeKey: Hashable {
        case value
        case sequence(elementCount: Int)
        case emptySequence
        case zip(childCount: Int)
        case bind
        case pick(branchCount: Int)
        case just
    }

    /// Computes the shape key for a graph node.
    private func nodeShapeKey(_ node: ChoiceGraphNode) -> NodeShapeKey {
        switch node.kind {
        case .chooseBits:
            return .value
        case let .sequence(metadata):
            if metadata.elementCount == 0 { return .emptySequence }
            return .sequence(elementCount: metadata.elementCount)
        case .zip:
            return .zip(childCount: node.children.count)
        case .bind:
            return .bind
        case let .pick(metadata):
            return .pick(branchCount: metadata.branchIDs.count)
        case .just:
            return .just
        }
    }
}
