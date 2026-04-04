//
//  GraphTransformation.swift
//  Exhaust
//

// MARK: - Transformation Kind

/// Identifies an encoder family for scheduling purposes.
///
/// Each kind corresponds to one ``GraphEncoder`` conformance. The scheduler uses this to select which encoder to run and in what order, based on the maximum yield any candidate of that kind could produce.
enum EncoderSlot: CaseIterable {
    /// Branch pivot: structural simplification via branch selection changes.
    case branchPivot

    /// Substitution: splice smaller subtrees along self-similarity edges.
    case substitution

    /// Sibling swap: reorder same-shaped siblings for shortlex improvement.
    case siblingSwap

    /// Deletion: remove sequence elements via adaptive batch sizing.
    case deletion

    /// Value search: binary search on integer leaf values toward their reduction target.
    case valueSearch

    /// Float search: four-stage IEEE 754 pipeline for floating-point leaves.
    case floatSearch

    /// Redistribution: speculative value swaps along type-compatibility edges.
    case redistribution

    /// Tandem: lockstep reduction of same-typed sibling values.
    case tandem
}

// MARK: - Yield Estimate

/// Estimated yield for an encoder family based on the current graph state.
///
/// The scheduler uses this to order encoder passes. Structural yield is the maximum sequence length reduction any single candidate could produce. Value yield is the maximum bound subtree size that reducing a leaf could structurally unlock.
struct EncoderYieldEstimate: Comparable {
    /// Whether this encoder operates on structure (deletion, substitution, pivot, swap) or values (value search, float search).
    let tier: Tier

    /// Estimated maximum sequence length reduction from the best candidate. Zero for value encoders.
    let structuralYield: Int

    /// Estimated maximum structural unlock from reducing a value leaf. Zero for structural encoders. Equal to the bound subtree size of the largest non-structurally-constant bind whose inner is not yet converged.
    let valueYield: Int

    /// Number of candidates available to this encoder.
    let candidateCount: Int

    enum Tier: Int, Comparable {
        /// Structural transformations run first (pass 1).
        case structural = 0
        /// Value transformations run second (pass 2).
        case value = 1

        static func < (lhs: Tier, rhs: Tier) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    static func < (lhs: EncoderYieldEstimate, rhs: EncoderYieldEstimate) -> Bool {
        if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
        if lhs.structuralYield != rhs.structuralYield { return lhs.structuralYield > rhs.structuralYield }
        if lhs.valueYield != rhs.valueYield { return lhs.valueYield > rhs.valueYield }
        return lhs.candidateCount > rhs.candidateCount
    }
}

// MARK: - Queue Builder

/// Computes yield estimates for each encoder family from the current graph state.
///
/// The scheduler sorts encoder families by yield estimate to determine pass ordering. Within each pass, encoders run to exhaustion (the internal probe loop handles candidate ordering).
enum TransformationQueueBuilder {

    /// Computes yield estimates for all encoder slots given the current graph.
    ///
    /// - Returns: Encoder slots paired with their yield estimates, sorted by priority (highest yield first within each tier).
    static func buildQueue(from graph: ChoiceGraph) -> [(slot: EncoderSlot, yield: EncoderYieldEstimate)] {
        var entries: [(slot: EncoderSlot, yield: EncoderYieldEstimate)] = []

        entries.append((.deletion, estimateDeletionYield(graph: graph)))
        entries.append((.substitution, estimateSubstitutionYield(graph: graph)))
        entries.append((.branchPivot, estimateBranchPivotYield(graph: graph)))
        entries.append((.siblingSwap, estimateSiblingSwapYield(graph: graph)))
        entries.append((.valueSearch, estimateValueSearchYield(graph: graph)))
        entries.append((.floatSearch, estimateFloatSearchYield(graph: graph)))

        // Filter out encoder slots with zero candidates.
        entries = entries.filter { $0.yield.candidateCount > 0 }

        // Sort by yield estimate (structural first, then by yield descending).
        entries.sort { $0.yield < $1.yield }

        return entries
    }

    // MARK: - Per-Encoder Yield Estimation

    /// Deletion yield: maximum subtree size among deletable sequence element children.
    private static func estimateDeletionYield(graph: ChoiceGraph) -> EncoderYieldEstimate {
        var maxYield = 0
        var candidateCount = 0
        for node in graph.nodes {
            guard node.positionRange != nil else { continue }
            guard let parentID = node.parent else { continue }
            guard case let .sequence(metadata) = graph.nodes[parentID].kind else { continue }
            let minLength = metadata.lengthConstraint?.lowerBound ?? 0
            guard UInt64(metadata.elementCount) > minLength else { continue }
            candidateCount += 1
            let size = node.positionRange?.count ?? 0
            if size > maxYield { maxYield = size }
        }
        return EncoderYieldEstimate(
            tier: .structural,
            structuralYield: maxYield,
            valueYield: 0,
            candidateCount: candidateCount
        )
    }

    /// Substitution yield: maximum size delta among self-similarity edges.
    private static func estimateSubstitutionYield(graph: ChoiceGraph) -> EncoderYieldEstimate {
        var maxYield = 0
        var candidateCount = 0
        for edge in graph.selfSimilarityEdges {
            let delta = abs(edge.sizeDelta)
            candidateCount += 1
            if delta > maxYield { maxYield = delta }
        }
        return EncoderYieldEstimate(
            tier: .structural,
            structuralYield: maxYield,
            valueYield: 0,
            candidateCount: candidateCount
        )
    }

    /// Branch pivot yield: estimated from inactive branch sizes relative to active branch.
    private static func estimateBranchPivotYield(graph: ChoiceGraph) -> EncoderYieldEstimate {
        var maxYield = 0
        var candidateCount = 0
        for node in graph.nodes {
            guard case let .pick(metadata) = node.kind else { continue }
            guard node.positionRange != nil else { continue }
            guard metadata.branchIDs.count >= 2 else { continue }
            candidateCount += 1
            // Conservative: the active branch size is the potential yield if
            // we pivot to a smaller branch.
            let activeSize = node.positionRange?.count ?? 0
            if activeSize > maxYield { maxYield = activeSize }
        }
        return EncoderYieldEstimate(
            tier: .structural,
            structuralYield: maxYield,
            valueYield: 0,
            candidateCount: candidateCount
        )
    }

    /// Sibling swap yield: zero structural yield (shortlex improvement only).
    private static func estimateSiblingSwapYield(graph: ChoiceGraph) -> EncoderYieldEstimate {
        var candidateCount = 0
        for node in graph.nodes {
            guard case .zip = node.kind else { continue }
            guard node.positionRange != nil else { continue }
            guard node.children.count >= 2 else { continue }
            candidateCount += 1
        }
        return EncoderYieldEstimate(
            tier: .structural,
            structuralYield: 0,
            valueYield: 0,
            candidateCount: candidateCount
        )
    }

    /// Value search yield: maximum bound subtree size for non-converged bind-inner leaves.
    private static func estimateValueSearchYield(graph: ChoiceGraph) -> EncoderYieldEstimate {
        var maxValueYield = 0
        var candidateCount = 0
        for nodeID in graph.leafNodes {
            let node = graph.nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind else { continue }
            guard metadata.typeTag.isFloatingPoint == false else { continue }

            let currentBitPattern = metadata.value.bitPattern64
            let targetBitPattern = metadata.value.reductionTarget(in: metadata.validRange)
            guard currentBitPattern != targetBitPattern else { continue }

            candidateCount += 1

            // Check if this leaf is a bind-inner controlling a non-constant bind.
            let boundSubtreeSize = bindInnerValueYield(
                leafNodeID: nodeID,
                graph: graph
            )
            if boundSubtreeSize > maxValueYield { maxValueYield = boundSubtreeSize }
        }
        return EncoderYieldEstimate(
            tier: .value,
            structuralYield: 0,
            valueYield: maxValueYield,
            candidateCount: candidateCount
        )
    }

    /// Float search yield: same logic as value search but for floating-point leaves.
    private static func estimateFloatSearchYield(graph: ChoiceGraph) -> EncoderYieldEstimate {
        var maxValueYield = 0
        var candidateCount = 0
        for nodeID in graph.leafNodes {
            let node = graph.nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind else { continue }
            guard metadata.typeTag.isFloatingPoint else { continue }

            candidateCount += 1

            let boundSubtreeSize = bindInnerValueYield(
                leafNodeID: nodeID,
                graph: graph
            )
            if boundSubtreeSize > maxValueYield { maxValueYield = boundSubtreeSize }
        }
        return EncoderYieldEstimate(
            tier: .value,
            structuralYield: 0,
            valueYield: maxValueYield,
            candidateCount: candidateCount
        )
    }

    // MARK: - Helpers

    /// Returns the bound subtree size if the given leaf is a bind-inner for a non-structurally-constant bind, otherwise zero.
    private static func bindInnerValueYield(leafNodeID: Int, graph: ChoiceGraph) -> Int {
        // Check if any bind node lists this leaf as its inner child.
        for node in graph.nodes {
            guard case let .bind(metadata) = node.kind else { continue }
            guard metadata.isStructurallyConstant == false else { continue }
            guard node.children.count >= 2 else { continue }
            let innerChildID = node.children[metadata.innerChildIndex]
            guard innerChildID == leafNodeID else { continue }
            let boundChildID = node.children[metadata.boundChildIndex]
            return graph.nodes[boundChildID].positionRange?.count ?? 0
        }
        return 0
    }
}
