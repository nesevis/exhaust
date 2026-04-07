//
//  ChoiceGraph+Scopes.swift
//  Exhaust
//

// MARK: - Removal Scope Queries

extension ChoiceGraph {

    /// Computes aligned removal scopes for all zip nodes with multiple sequence children.
    ///
    /// An aligned tuple groups elements at corresponding offsets across sibling sequences. The scope provides siblings and their deletable elements in natural offset order — the encoder handles window placement (head-aligned, tail-aligned, or both) within its probe loop, analogous to head/tail alternation in per-parent removal.
    ///
    /// Computes aligned removal scopes for all zip nodes with multiple sequence children, including partial sibling subsets.
    ///
    /// Looks through transparent wrappers (groups, structurally-constant binds) beneath each zip child to find the underlying sequence node. Generates scopes for all subsets of siblings of size 2 or more. The full-sibling scope has the highest yield and runs first in the queue. Progressively smaller subsets (triples, pairs) follow in yield order.
    ///
    /// - Returns: One scope per sibling subset (size >= 2) per zip node.
    func alignedRemovalScopes() -> [AlignedRemovalScope] {
        var scopes: [AlignedRemovalScope] = []
        for node in nodes {
            guard case .zip = node.kind else { continue }
            guard node.positionRange != nil else { continue }

            let allSequenceChildren = node.children.compactMap { childID
                -> SiblingDeletionScope? in
                guard let sequenceNodeID = findSequenceBeneath(childID) else {
                    return nil
                }
                let sequenceNode = nodes[sequenceNodeID]
                guard case let .sequence(metadata) = sequenceNode.kind else {
                    return nil
                }
                let minLength = Int(metadata.lengthConstraint?.lowerBound ?? 0)
                let deletable = metadata.elementCount - minLength
                guard deletable > 0 else { return nil }
                return SiblingDeletionScope(
                    sequenceNodeID: sequenceNodeID,
                    elementNodeIDs: sequenceNode.children,
                    deletableCount: deletable
                )
            }
            guard allSequenceChildren.count >= 2 else { continue }

            // Generate scopes for all subsets of size 2 through N.
            // Largest subsets first (highest yield). The yield ordering in
            // the queue ensures the most drastic (all-sibling) probes run
            // before pairs.
            let subsets = siblingSubsets(allSequenceChildren)
            for subset in subsets {
                let maxWindow = subset.map(\.deletableCount).min() ?? 0
                guard maxWindow > 0 else { continue }

                var totalYield = 0
                for sibling in subset {
                    for elementNodeID in sibling.elementNodeIDs {
                        totalYield += nodes[elementNodeID].positionRange?.count ?? 0
                    }
                }

                scopes.append(AlignedRemovalScope(
                    zipNodeID: node.id,
                    siblings: subset,
                    maxAlignedWindow: maxWindow,
                    maxYield: totalYield
                ))
            }
        }
        return scopes
    }

    /// Generates all subsets of size 2 or more from the given siblings, ordered by descending size (largest subsets first).
    private func siblingSubsets(_ siblings: [SiblingDeletionScope]) -> [[SiblingDeletionScope]] {
        let count = siblings.count
        guard count >= 2 else { return [] }

        var subsets: [[SiblingDeletionScope]] = []

        // Generate subsets from largest (all) to smallest (pairs).
        // For N siblings, iterate subset sizes from N down to 2.
        for size in stride(from: count, through: 2, by: -1) {
            generateCombinations(siblings, choose: size, into: &subsets)
        }

        return subsets
    }

    /// Appends all combinations of `choose` elements from `source` into `result`.
    private func generateCombinations(
        _ source: [SiblingDeletionScope],
        choose: Int,
        into result: inout [[SiblingDeletionScope]]
    ) {
        let count = source.count
        guard choose >= 1, choose <= count else { return }

        // Iterative combination generation using indices.
        var indices = Array(0 ..< choose)
        while true {
            result.append(indices.map { source[$0] })

            // Find the rightmost index that can be incremented.
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

    /// Walks through transparent wrappers (groups, structurally-constant binds) beneath a node to find the first sequence node.
    ///
    /// Returns the sequence node's ID, or nil if no sequence is found beneath the transparent chain.
    private func findSequenceBeneath(_ nodeID: Int) -> Int? {
        let node = nodes[nodeID]
        // Direct sequence — return immediately.
        if case .sequence = node.kind {
            return nodeID
        }
        // Transparent wrapper: zip (inner group from filter/contramap) or
        // structurally-constant bind — walk into the single meaningful child.
        switch node.kind {
        case .zip:
            // A zip beneath a zip is a transparent group wrapper (for example,
            // from filter). Walk into each child looking for a sequence.
            for childID in node.children {
                if let found = findSequenceBeneath(childID) {
                    return found
                }
            }
            return nil
        case let .bind(metadata):
            // Structurally-constant binds are transparent — the bound subtree's
            // shape doesn't depend on the inner value.
            if metadata.isStructurallyConstant, node.children.count >= 2 {
                let boundChildID = node.children[metadata.boundChildIndex]
                return findSequenceBeneath(boundChildID)
            }
            // Non-constant binds are not transparent — the sequence inside
            // depends on the bind-inner value and may change shape.
            return nil
        case .chooseBits, .pick:
            return nil
        case .sequence:
            return nodeID
        }
    }

    /// Computes per-parent removal scopes for all sequence nodes with deletable elements.
    ///
    /// Groups deletable elements by their parent sequence node. Each scope contains the elements in position order, the maximum batch size, and the yield of the largest single element.
    ///
    /// - Returns: One scope per sequence node with at least one deletable element.
    func perParentRemovalScopes() -> [PerParentRemovalScope] {
        var parentGroups: [Int: [Int]] = [:]

        for node in nodes {
            guard node.positionRange != nil else { continue }
            guard let parentID = node.parent else { continue }
            guard case let .sequence(metadata) = nodes[parentID].kind else { continue }
            let minLength = metadata.lengthConstraint?.lowerBound ?? 0
            guard UInt64(metadata.elementCount) > minLength else { continue }
            parentGroups[parentID, default: []].append(node.id)
        }

        return parentGroups.map { parentID, elementNodeIDs in
            let sortedElements = elementNodeIDs.sorted { nodeA, nodeB in
                let rangeA = nodes[nodeA].positionRange?.lowerBound ?? 0
                let rangeB = nodes[nodeB].positionRange?.lowerBound ?? 0
                return rangeA < rangeB
            }
            let maxElementYield = sortedElements.reduce(0) { maxSoFar, nodeID in
                max(maxSoFar, nodes[nodeID].positionRange?.count ?? 0)
            }
            guard case let .sequence(metadata) = nodes[parentID].kind else {
                // Should not happen — we only collected elements with sequence parents.
                return PerParentRemovalScope(
                    sequenceNodeID: parentID,
                    elementNodeIDs: sortedElements,
                    maxBatch: sortedElements.count,
                    maxElementYield: maxElementYield
                )
            }
            let minLength = Int(metadata.lengthConstraint?.lowerBound ?? 0)
            let deletable = metadata.elementCount - minLength
            return PerParentRemovalScope(
                sequenceNodeID: parentID,
                elementNodeIDs: sortedElements,
                maxBatch: deletable,
                maxElementYield: maxElementYield
            )
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
                    mayReshapeOnAcceptance: isBindInnerOfNonConstantBind(
                        nodeID,
                        innerChildToBind: innerChildToBind
                    )
                )
            }
            scopes.append(.integerLeaves(IntegerMinimizationScope(
                leaves: entries,
                batchZeroEligible: entries.count > 1
            )))
        }

        if floatLeafNodeIDs.isEmpty == false {
            let entries = floatLeafNodeIDs.map { nodeID in
                LeafEntry(
                    nodeID: nodeID,
                    mayReshapeOnAcceptance: isBindInnerOfNonConstantBind(
                        nodeID,
                        innerChildToBind: innerChildToBind
                    )
                )
            }
            scopes.append(.floatLeaves(FloatMinimizationScope(leaves: entries)))
        }

        // Kleisli fibre: one scope per non-constant reduction edge.
        for edge in reductionEdges {
            guard edge.isStructurallyConstant == false else { continue }
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

    /// Computes value yield for a leaf: the bound subtree size if this leaf is a bind-inner for a non-structurally-constant bind, otherwise zero.
    private func computeValueYield(
        leafNodeID: Int,
        innerChildToBind: [Int: Int]
    ) -> Int {
        guard let bindNodeID = innerChildToBind[leafNodeID] else { return 0 }
        guard case let .bind(metadata) = nodes[bindNodeID].kind else { return 0 }
        guard metadata.isStructurallyConstant == false else { return 0 }
        guard nodes[bindNodeID].children.count >= 2 else { return 0 }
        let boundChildID = nodes[bindNodeID].children[metadata.boundChildIndex]
        return nodes[boundChildID].positionRange?.count ?? 0
    }

    /// Returns true when a leaf is the inner child of a non-structurally-constant bind. Mutating its value may trigger a downstream bound subtree rebuild, which the partial-rebuild path routes through ``ChoiceGraph/apply(_:freshTree:)`` separately from pure value-only changes.
    func isBindInnerOfNonConstantBind(
        _ leafNodeID: Int,
        innerChildToBind: [Int: Int]
    ) -> Bool {
        guard let bindNodeID = innerChildToBind[leafNodeID] else { return false }
        guard case let .bind(metadata) = nodes[bindNodeID].kind else { return false }
        return metadata.isStructurallyConstant == false
    }

    /// Wraps a leaf node ID in a ``LeafEntry`` with the bind-inner reshape marker populated from the supplied index.
    func makeLeafEntry(
        _ nodeID: Int,
        innerChildToBind: [Int: Int]
    ) -> LeafEntry {
        LeafEntry(
            nodeID: nodeID,
            mayReshapeOnAcceptance: isBindInnerOfNonConstantBind(
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

    /// Computes redistribution pairs for the speculative relax round.
    ///
    /// Unlike ``exchangeScopes()``, this emits pairs in BOTH directions for every type-compatible edge — no source-earlier-than-receiver constraint. The shortlex gate is bypassed during the speculative phase; only the final comparison against the checkpoint determines acceptance.
    func speculativeExchangeScopes() -> [ExchangeScope] {
        let innerChildToBind = buildInnerChildToBind()
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

            // Emit both directions for any edge where at least one leaf is not at target.
            if distanceA > 0 {
                pairs.append(RedistributionPair(
                    source: makeLeafEntry(edge.nodeA, innerChildToBind: innerChildToBind),
                    sink: makeLeafEntry(edge.nodeB, innerChildToBind: innerChildToBind),
                    sourceTag: metadataA.typeTag,
                    sinkTag: metadataB.typeTag
                ))
            }
            if distanceB > 0 {
                pairs.append(RedistributionPair(
                    source: makeLeafEntry(edge.nodeB, innerChildToBind: innerChildToBind),
                    sink: makeLeafEntry(edge.nodeA, innerChildToBind: innerChildToBind),
                    sourceTag: metadataB.typeTag,
                    sinkTag: metadataA.typeTag
                ))
            }
        }
        guard pairs.isEmpty == false else { return [] }
        return [.redistribution(RedistributionScope(pairs: pairs))]
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
        }
    }
}
