/// Enumerates replacement pairs over complete pick families without storing every pair scope.
///
/// Priority enumeration merges rows whose donors are ordered by subtree size. Each row contributes one heap entry, preserving descending structural benefit and the eager builder's discovery order for ties. Descendant eligibility is checked only when its row reaches the head, so unrelated families do not pay an all-pairs reachability scan during preparation.
///
/// The discovery order is also available to the relax round, whose candidate-length sort relies on the original replacement order for ties. The cursor retains immutable topology and compact pick descriptors rather than the graph's mutable node array.
///
/// - Complexity: O(P + B + V + E) retained state, where P is the number of family members, B is the prepared branch metadata, and V + E is the topology snapshot. Preparation sorts family members in O(P log P) time and performs the existing branch eligibility scans. Heap advancement costs O(log R), where R is the number of pending rows, plus any descendant reachability checks and rejected entries encountered before the next valid scope.
struct ReplacementCandidateSource {
    /// Keeps scheduling order separate from discovery order used by structural relaxation.
    enum EnumerationOrder {
        case priority
        case discovery
    }

    private struct Member {
        let nodeID: Int
        let size: Int
        let originalIndex: Int
        let liveOrder: Int
        let isActive: Bool
    }

    private struct Family {
        let members: [Member]
        let sizeOrder: [Int]
    }

    private struct Pivot {
        let nodeID: Int
        let size: Int
        let liveOrder: Int
        let branches: [UInt64]
    }

    private enum Row {
        case selfSimilar(familyIndex: Int, targetIndex: Int, donorIndex: Int)
        case pivot(pivotIndex: Int, branchIndex: Int)
        case promotion(familyIndex: Int, targetIndex: Int, donorIndex: Int)
    }

    /// Separates heap ranking from the emitted priority so discovery enumeration can retain its original order.
    private struct Entry: Comparable {
        let row: Row
        let benefit: Int
        let rank: Int
        let discoveryOrder: (Int, Int, Int, Int)

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.rank != rhs.rank {
                return lhs.rank < rhs.rank
            }
            return lhs.discoveryOrder > rhs.discoveryOrder
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.rank == rhs.rank && lhs.discoveryOrder == rhs.discoveryOrder
        }
    }

    private let families: [Family]
    private let pivots: [Pivot]
    private let parentNodeIDs: [Int?]
    private let dependencyAdjacency: [[Int]]
    private let order: EnumerationOrder
    private var pendingRows = ScopePriorityQueue<Entry>()
    private var pendingTransformation: GraphTransformation?

    /// Prepares complete family membership and pivot eligibility, deferring pair scopes and descendant checks until enumeration.
    init(
        graph: ChoiceGraph,
        previousGraph: ChoiceGraph? = nil,
        order: EnumerationOrder = .priority,
        onlyPivots: Bool = false
    ) {
        self.order = order
        let unchanged = ReplacementQuery.unchangedFingerprints(graph: graph, previousGraph: previousGraph)
        var preparedFamilies: [Family] = []
        if onlyPivots == false {
            let liveOrder = Dictionary(uniqueKeysWithValues: graph.liveNodeIDs.enumerated().map { ($0.element, $0.offset) })
            for (fingerprint, nodeIDs) in graph.selfSimilarityGroups {
                guard nodeIDs.count >= 2, unchanged.contains(fingerprint) == false else {
                    continue
                }
                let members = nodeIDs.enumerated().map { index, nodeID in
                    Member(
                        nodeID: nodeID,
                        size: graph.nodes[nodeID].positionRange?.count ?? 0,
                        originalIndex: index,
                        liveOrder: liveOrder[nodeID] ?? nodeID,
                        isActive: graph.nodes[nodeID].positionRange != nil
                    )
                }
                let sizeOrder = members.indices.sorted { first, second in
                    if members[first].size != members[second].size {
                        return members[first].size < members[second].size
                    }
                    return first < second
                }
                preparedFamilies.append(Family(members: members, sizeOrder: sizeOrder))
            }
        }
        families = preparedFamilies
        pivots = graph.liveNodeIDs.enumerated().compactMap { liveIndex, nodeID in
            let node = graph.nodes[nodeID]
            guard case let .pick(metadata) = node.kind,
                  metadata.branchCount >= 2,
                  node.children.count == Int(metadata.branchCount)
            else {
                return nil
            }
            let selectedLeafCount = ReplacementQuery.leafCount(in: metadata.branchElements[metadata.selectedChildIndex])
            let excluded = graph.excludedPivotTargets(for: metadata)
            let branches = (0 ..< Int(metadata.branchCount)).compactMap { index -> UInt64? in
                let branchID = UInt64(index)
                guard branchID != metadata.selectedID,
                      excluded.contains(branchID) == false,
                      ReplacementQuery.leafCount(in: metadata.branchElements[index]) <= selectedLeafCount
                else {
                    return nil
                }
                return branchID
            }
            guard branches.isEmpty == false else {
                return nil
            }
            return Pivot(nodeID: nodeID, size: node.positionRange?.count ?? 0, liveOrder: liveIndex, branches: branches)
        }
        parentNodeIDs = families.isEmpty ? [] : graph.nodes.map(\.parent)
        dependencyAdjacency = families.isEmpty ? [] : graph.dependencyAdjacency
        seedRows()
        prepareNext()
    }

    /// Seeds O(P) pair rows, with one pending entry per target rather than one entry per target/donor combination.
    private mutating func seedRows() {
        for (familyIndex, family) in families.enumerated() {
            switch order {
                case .priority:
                    for targetIndex in 1 ..< family.members.count {
                        insert(.selfSimilar(familyIndex: familyIndex, targetIndex: targetIndex, donorIndex: 0))
                    }
                case .discovery:
                    for targetIndex in 0 ..< family.members.count - 1 {
                        insert(.selfSimilar(familyIndex: familyIndex, targetIndex: targetIndex, donorIndex: targetIndex + 1))
                    }
            }
            for targetIndex in family.members.indices where family.members[targetIndex].isActive {
                insert(.promotion(familyIndex: familyIndex, targetIndex: targetIndex, donorIndex: 0))
            }
        }
        for pivotIndex in pivots.indices {
            insert(.pivot(pivotIndex: pivotIndex, branchIndex: 0))
        }
    }

    /// Computes only row ordering metadata; promotion validity is deferred until the row is selected.
    private mutating func insert(_ row: Row) {
        let benefit: Int
        let discoveryOrder: (Int, Int, Int, Int)
        switch row {
            case let .selfSimilar(familyIndex, targetIndex, donorIndex):
                let family = families[familyIndex]
                let donorLimit = order == .priority ? targetIndex : family.members.count
                guard donorIndex < donorLimit else {
                    return
                }
                let target = member(in: family, at: targetIndex)
                let donor = member(in: family, at: donorIndex)
                benefit = abs(target.size - donor.size)
                discoveryOrder = (0, familyIndex, min(target.originalIndex, donor.originalIndex), max(target.originalIndex, donor.originalIndex))
            case let .pivot(pivotIndex, branchIndex):
                let pivot = pivots[pivotIndex]
                guard branchIndex < pivot.branches.count else {
                    return
                }
                benefit = pivot.size
                discoveryOrder = (1, pivot.liveOrder, branchIndex, 0)
            case let .promotion(familyIndex, targetIndex, donorIndex):
                let family = families[familyIndex]
                guard donorIndex < family.members.count else {
                    return
                }
                let target = family.members[targetIndex]
                let donor = member(in: family, at: donorIndex)
                benefit = target.size - donor.size
                guard order == .discovery || benefit > 0 else {
                    return
                }
                discoveryOrder = (2, target.liveOrder, donor.originalIndex, 0)
        }
        pendingRows.insert(Entry(
            row: row,
            benefit: benefit,
            rank: order == .priority ? benefit : 0,
            discoveryOrder: discoveryOrder
        ))
    }

    private func member(in family: Family, at index: Int) -> Member {
        family.members[order == .priority ? family.sizeOrder[index] : index]
    }

    /// Advances only the selected row, skipping ineligible descendant promotions without buffering their scopes.
    private mutating func prepareNext() {
        pendingTransformation = nil
        while let entry = pendingRows.popFirst() {
            let scope = scope(for: entry)
            switch entry.row {
                case let .selfSimilar(familyIndex, targetIndex, donorIndex):
                    insert(.selfSimilar(familyIndex: familyIndex, targetIndex: targetIndex, donorIndex: donorIndex + 1))
                case let .pivot(pivotIndex, branchIndex):
                    insert(.pivot(pivotIndex: pivotIndex, branchIndex: branchIndex + 1))
                case let .promotion(familyIndex, targetIndex, donorIndex):
                    insert(.promotion(familyIndex: familyIndex, targetIndex: targetIndex, donorIndex: donorIndex + 1))
            }
            guard let scope else {
                continue
            }
            pendingTransformation = GraphTransformation(
                operation: .replace(scope),
                priority: DispatchPriority(structuralBenefit: entry.benefit, valueBenefit: 0, reductionMagnitude: 0, estimatedCost: 1)
            )
            return
        }
    }

    /// Constructs the selected scope, retaining original orientation for equal-size self-similar pairs.
    private func scope(for entry: Entry) -> ReplacementScope? {
        switch entry.row {
            case let .selfSimilar(familyIndex, targetIndex, donorIndex):
                let family = families[familyIndex]
                let first = member(in: family, at: targetIndex)
                let second = member(in: family, at: donorIndex)
                let keepsFirst = first.size > second.size || (first.size == second.size && first.originalIndex < second.originalIndex)
                let target = keepsFirst ? first : second
                let donor = keepsFirst ? second : first
                return .selfSimilar(targetNodeID: target.nodeID, donorNodeID: donor.nodeID, sizeDelta: entry.benefit)
            case let .pivot(pivotIndex, branchIndex):
                let pivot = pivots[pivotIndex]
                return .branchPivot(pickNodeID: pivot.nodeID, targetBranchID: pivot.branches[branchIndex])
            case let .promotion(familyIndex, targetIndex, donorIndex):
                let family = families[familyIndex]
                let target = family.members[targetIndex]
                let donor = member(in: family, at: donorIndex)
                guard target.nodeID != donor.nodeID, donor.isActive, entry.benefit > 0,
                      isDescendant(donor.nodeID, of: target.nodeID)
                      || DependencyReachability.isReachable(from: target.nodeID, to: donor.nodeID, adjacency: dependencyAdjacency)
                else {
                    return nil
                }
                return .descendantPromotion(ancestorPickNodeID: target.nodeID, descendantPickNodeID: donor.nodeID, sizeDelta: entry.benefit)
        }
    }

    private func isDescendant(_ nodeID: Int, of ancestorNodeID: Int) -> Bool {
        var current = nodeID
        while let parent = parentNodeIDs[current] {
            if parent == ancestorNodeID {
                return true
            }
            current = parent
        }
        return false
    }
}

extension ReplacementCandidateSource: CandidateSource {
    var peekPriority: DispatchPriority? {
        pendingTransformation?.priority
    }

    var isValueDependent: Bool {
        false
    }

    var isPermutationSource: Bool {
        false
    }

    mutating func next(lastAccepted _: Bool) -> GraphTransformation? {
        guard let transformation = pendingTransformation else {
            return nil
        }
        prepareNext()
        return transformation
    }
}
