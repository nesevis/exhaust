/// Enumerates replacement pairs over complete pick families without storing every pair scope.
///
/// Priority enumeration merges rows whose donors are ordered by subtree size. Each row contributes one heap entry, preserving descending structural benefit and discovery order for ties. Descendant eligibility is checked only when its row reaches the head, so unrelated families do not pay an all-pairs reachability scan during preparation.
///
/// The discovery order is also available to the relax round, whose candidate-length sort relies on the original replacement order for ties. The cursor retains immutable topology and compact pick descriptors rather than the graph's mutable node array.
///
/// - Complexity: O(P + B + V + E) retained state, where P is the number of family members, B is the prepared branch metadata, and V + E is the topology snapshot. Preparation sorts family members in O(P log P) time and performs the existing branch eligibility scans. Containment is indexed in O(V) time and queried in O(1). Heap advancement costs O(log R), where R is the number of pending rows, plus rejected entries and dependency cache misses encountered before the next valid scope. Each cache miss costs O(V + E); cached membership is expected O(1). The dependency cache retains a bounded working set of restricted results, plus O(V) negative-source identities, within the overall storage bound.
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
        let discoveryOrder: [Int]
    }

    private struct Pivot {
        let nodeID: Int
        let size: Int
        let liveOrder: Int
        let branches: [UInt64]
    }

    /// Both target and donor indices always address the family's original membership array.
    ///
    /// Immutable slices share the family's donor ordering; advancing a row drops its first index without copying the remaining indices.
    private struct PairRow {
        let familyIndex: Int
        let targetIndex: Int
        var donorIndices: ArraySlice<Int>
    }

    private enum Row {
        case selfSimilar(PairRow)
        case pivot(pivotIndex: Int, branchIndex: Int)
        case promotion(PairRow)
    }

    /// Carries scheduling benefit separately from the discovery tie-breaker.
    private struct Entry {
        let row: Row
        let benefit: Int
        let discoveryOrder: (Int, Int, Int, Int)

        static func priorityPrecedes(_ first: Self, _ second: Self) -> Bool {
            if first.benefit != second.benefit {
                return first.benefit > second.benefit
            }
            return discoveryPrecedes(first, second)
        }

        static func discoveryPrecedes(_ first: Self, _ second: Self) -> Bool {
            first.discoveryOrder < second.discoveryOrder
        }
    }

    private let families: [Family]
    private let pivots: [Pivot]
    private let containment: ContainmentIndex
    private var dependencyReachability: DependencyReachabilityCache
    private var pendingRows: ScopePriorityQueue<Entry>
    private var pendingTransformation: GraphTransformation?

    /// Prepares complete families once, then selects a seeding strategy before enumeration begins.
    init(graph: ChoiceGraph, previousGraph: ChoiceGraph? = nil, order: EnumerationOrder = .priority) {
        self.init(graph: graph, families: Self.prepareFamilies(graph: graph, previousGraph: previousGraph), order: order)
    }

    /// Avoids family and reachability preparation when relaxation needs only branch pivots.
    init(pivotGraph graph: ChoiceGraph) {
        self.init(graph: graph, families: [], order: .discovery)
    }

    /// Retains original identities independently of the size ordering used by priority rows.
    private static func prepareFamilies(graph: ChoiceGraph, previousGraph: ChoiceGraph?) -> [Family] {
        let unchanged = ReplacementQuery.unchangedFingerprints(graph: graph, previousGraph: previousGraph)
        let liveOrder = Dictionary(uniqueKeysWithValues: graph.liveNodeIDs.enumerated().map { ($0.element, $0.offset) })
        return graph.selfSimilarityGroups.compactMap { fingerprint, nodeIDs in
            guard nodeIDs.count >= 2, unchanged.contains(fingerprint) == false else {
                return nil
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
            return Family(members: members, sizeOrder: sizeOrder, discoveryOrder: Array(members.indices))
        }
    }

    /// Common preparation captures pivot eligibility and topology before either seeding strategy runs.
    private init(graph: ChoiceGraph, families: [Family], order: EnumerationOrder) {
        self.families = families
        pendingRows = switch order {
            case .priority:
                ScopePriorityQueue<Entry>(precedes: Entry.priorityPrecedes)
            case .discovery:
                ScopePriorityQueue<Entry>(precedes: Entry.discoveryPrecedes)
        }
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
        containment = ContainmentIndex(parentNodeIDs: families.isEmpty ? [] : graph.nodes.map(\.parent))
        let candidateNodeIDs = Set(families.flatMap { family in
            family.members.filter(\.isActive).map(\.nodeID)
        })
        dependencyReachability = DependencyReachabilityCache(
            adjacency: families.isEmpty ? [] : graph.dependencyAdjacency,
            candidates: candidateNodeIDs
        )
        switch order {
            case .priority:
                seedPriorityRows()
            case .discovery:
                seedDiscoveryRows()
        }
        for pivotIndex in pivots.indices {
            insert(.pivot(pivotIndex: pivotIndex, branchIndex: 0))
        }
        prepareNext()
    }

    /// Merges size-ordered donor prefixes so every row emits non-increasing benefit.
    ///
    /// Equal-sized targets share the same strictly smaller donor prefix for promotion. Self-similarity includes equal sizes and uses original identities to orient ties.
    private mutating func seedPriorityRows() {
        for (familyIndex, family) in families.enumerated() {
            var smallerDonorCount = 0
            for (offset, targetIndex) in family.sizeOrder.enumerated() {
                if offset > 0, family.members[targetIndex].size != family.members[family.sizeOrder[offset - 1]].size {
                    smallerDonorCount = offset
                }
                insert(.selfSimilar(PairRow(familyIndex: familyIndex, targetIndex: targetIndex, donorIndices: family.sizeOrder[..<offset])))
                if family.members[targetIndex].isActive {
                    insert(.promotion(PairRow(familyIndex: familyIndex, targetIndex: targetIndex, donorIndices: family.sizeOrder[..<smallerDonorCount])))
                }
            }
        }
    }

    /// Preserves family pair discovery and positional promotion order, filtering eligibility when each row is visited.
    private mutating func seedDiscoveryRows() {
        for (familyIndex, family) in families.enumerated() {
            for targetIndex in family.members.indices {
                insert(.selfSimilar(PairRow(familyIndex: familyIndex, targetIndex: targetIndex, donorIndices: family.discoveryOrder[(targetIndex + 1)...])))
                if family.members[targetIndex].isActive {
                    insert(.promotion(PairRow(familyIndex: familyIndex, targetIndex: targetIndex, donorIndices: family.discoveryOrder[...])))
                }
            }
        }
    }

    /// Computes only row ordering metadata; promotion validity is deferred until the row is selected.
    private mutating func insert(_ row: Row) {
        let benefit: Int
        let discoveryOrder: (Int, Int, Int, Int)
        switch row {
            case let .selfSimilar(pair):
                let family = families[pair.familyIndex]
                guard let donorIndex = pair.donorIndices.first else {
                    return
                }
                let target = family.members[pair.targetIndex]
                let donor = family.members[donorIndex]
                benefit = abs(target.size - donor.size)
                discoveryOrder = (0, pair.familyIndex, min(target.originalIndex, donor.originalIndex), max(target.originalIndex, donor.originalIndex))
            case let .pivot(pivotIndex, branchIndex):
                let pivot = pivots[pivotIndex]
                guard branchIndex < pivot.branches.count else {
                    return
                }
                benefit = pivot.size
                discoveryOrder = (1, pivot.liveOrder, branchIndex, 0)
            case let .promotion(pair):
                let family = families[pair.familyIndex]
                guard let donorIndex = pair.donorIndices.first else {
                    return
                }
                let target = family.members[pair.targetIndex]
                let donor = family.members[donorIndex]
                benefit = target.size - donor.size
                discoveryOrder = (2, target.liveOrder, donor.originalIndex, 0)
        }
        pendingRows.insert(Entry(
            row: row,
            benefit: benefit,
            discoveryOrder: discoveryOrder
        ))
    }

    /// Advances only the selected row, skipping ineligible descendant promotions without buffering their scopes.
    private mutating func prepareNext() {
        pendingTransformation = nil
        while let entry = pendingRows.popFirst() {
            let scope = scope(for: entry)
            switch entry.row {
                case var .selfSimilar(pair):
                    pair.donorIndices = pair.donorIndices.dropFirst()
                    insert(.selfSimilar(pair))
                case let .pivot(pivotIndex, branchIndex):
                    insert(.pivot(pivotIndex: pivotIndex, branchIndex: branchIndex + 1))
                case var .promotion(pair):
                    pair.donorIndices = pair.donorIndices.dropFirst()
                    insert(.promotion(pair))
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
    ///
    /// Inserted pair rows always have a nonempty donor slice; exhaustion is rejected before a row enters the heap.
    private mutating func scope(for entry: Entry) -> ReplacementScope? {
        switch entry.row {
            case let .selfSimilar(pair):
                let family = families[pair.familyIndex]
                let first = family.members[pair.targetIndex]
                let second = family.members[pair.donorIndices[pair.donorIndices.startIndex]]
                let keepsFirst = first.size > second.size || (first.size == second.size && first.originalIndex < second.originalIndex)
                let target = keepsFirst ? first : second
                let donor = keepsFirst ? second : first
                return .selfSimilar(targetNodeID: target.nodeID, donorNodeID: donor.nodeID, sizeDelta: entry.benefit)
            case let .pivot(pivotIndex, branchIndex):
                let pivot = pivots[pivotIndex]
                return .branchPivot(pickNodeID: pivot.nodeID, targetBranchID: pivot.branches[branchIndex])
            case let .promotion(pair):
                let family = families[pair.familyIndex]
                let target = family.members[pair.targetIndex]
                let donor = family.members[pair.donorIndices[pair.donorIndices.startIndex]]
                guard target.nodeID != donor.nodeID, donor.isActive, entry.benefit > 0,
                      containment.isDescendant(donor.nodeID, of: target.nodeID)
                      || dependencyReachability.isReachable(from: target.nodeID, to: donor.nodeID)
                else {
                    return nil
                }
                return .descendantPromotion(ancestorPickNodeID: target.nodeID, descendantPickNodeID: donor.nodeID, sizeDelta: entry.benefit)
        }
    }

    /// Exposes actual dependency search work for profiling scope preparation and enumeration.
    var dependencyTraversalCount: Int {
        dependencyReachability.traversalCount
    }
}

extension ReplacementCandidateSource: CandidateSource {
    var peekPriority: DispatchPriority? {
        pendingTransformation?.priority
    }

    mutating func next() -> GraphTransformation? {
        guard let transformation = pendingTransformation else {
            return nil
        }
        prepareNext()
        return transformation
    }
}
