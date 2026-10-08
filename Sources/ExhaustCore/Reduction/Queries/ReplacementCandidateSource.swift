/// Enumerates replacement pairs over complete pick families without storing every pair scope.
///
/// Priority enumeration merges rows whose donors are ordered by subtree size. Each row contributes one heap entry, preserving descending structural benefit and discovery order for ties. Descendant eligibility is checked only when its row reaches the head, so unrelated families do not pay an all-pairs reachability scan during preparation.
///
/// The discovery order is also available to the relax round, whose candidate-length sort relies on the original replacement order for ties. The cursor retains immutable topology and compact pick descriptors rather than the graph's mutable node array.
///
/// Domains with at most ``defaultEagerRowLimit`` candidate rows skip the heap: direct loops enumerate every scope in discovery order, and priority order stable-sorts that list by benefit. Both paths emit identical streams; the heap only pays for itself when the row count makes buffering every scope expensive.
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
    }

    private struct Pivot {
        let nodeID: Int
        let size: Int
        let liveOrder: Int
        let branches: [UInt64]
    }

    /// Selects whether a row's donor positions index the family's size order or its original membership.
    private enum DonorOrder {
        case size
        case original
    }

    /// Holds only integers, so heap swaps copy rows without reference counting.
    ///
    /// The target index always addresses the family's original membership array; donor positions in `nextDonor ..< donorEnd` are resolved through `donorOrder`.
    private struct PairRow {
        let familyIndex: Int
        let targetIndex: Int
        let donorOrder: DonorOrder
        var nextDonor: Int
        let donorEnd: Int
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
    private var bufferedScopes: BufferedScopeCursor<GraphTransformation>?
    private var pendingTransformation: GraphTransformation?

    /// Candidate rows above which enumeration merges rows through the heap instead of buffering every scope.
    static let defaultEagerRowLimit = 1024

    /// Prepares complete families once, then selects a seeding strategy before enumeration begins.
    init(graph: ChoiceGraph, previousGraph: ChoiceGraph? = nil, order: EnumerationOrder = .priority, eagerRowLimit: Int = defaultEagerRowLimit) {
        self.init(graph: graph, families: Self.prepareFamilies(graph: graph, previousGraph: previousGraph), order: order, eagerRowLimit: eagerRowLimit)
    }

    /// Avoids family and reachability preparation when relaxation needs only branch pivots.
    init(pivotGraph graph: ChoiceGraph, eagerRowLimit: Int = defaultEagerRowLimit) {
        self.init(graph: graph, families: [], order: .discovery, eagerRowLimit: eagerRowLimit)
    }

    /// Retains original identities independently of the size ordering used by priority rows.
    private static func prepareFamilies(graph: ChoiceGraph, previousGraph: ChoiceGraph?) -> [Family] {
        let unchanged = ReplacementQuery.unchangedFingerprints(graph: graph, previousGraph: previousGraph)
        // Indexed by node ID and built only once a family needs it; graphs without self-similar picks skip the pass.
        var liveOrder: [Int]?
        return graph.selfSimilarityGroups.compactMap { fingerprint, nodeIDs in
            guard nodeIDs.count >= 2, unchanged.contains(fingerprint) == false else {
                return nil
            }
            let order = liveOrder ?? Self.liveOrder(of: graph)
            liveOrder = order
            let members = nodeIDs.enumerated().map { index, nodeID in
                Member(
                    nodeID: nodeID,
                    size: graph.nodes[nodeID].positionRange?.count ?? 0,
                    originalIndex: index,
                    liveOrder: order[nodeID] >= 0 ? order[nodeID] : nodeID,
                    isActive: graph.nodes[nodeID].positionRange != nil
                )
            }
            let sizeOrder = members.indices.sorted { first, second in
                if members[first].size != members[second].size {
                    return members[first].size < members[second].size
                }
                return first < second
            }
            return Family(members: members, sizeOrder: sizeOrder)
        }
    }

    /// Maps each node ID to its position among live nodes, or -1 for inactive nodes.
    private static func liveOrder(of graph: ChoiceGraph) -> [Int] {
        var order = [Int](repeating: -1, count: graph.nodes.count)
        for (offset, nodeID) in graph.liveNodeIDs.enumerated() {
            order[nodeID] = offset
        }
        return order
    }

    /// Common preparation captures pivot eligibility and topology before either seeding strategy runs.
    private init(graph: ChoiceGraph, families: [Family], order: EnumerationOrder, eagerRowLimit: Int) {
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
        let isEager = Self.rowCount(families: families, pivots: pivots) <= eagerRowLimit
        // The eager path checks containment by walking parent links for each candidate promotion, so it never needs the index.
        containment = ContainmentIndex(parentNodeIDs: families.isEmpty || isEager ? [] : graph.nodes.map(\.parent))
        let candidateNodeIDs = Set(families.flatMap { family in
            family.members.filter(\.isActive).map(\.nodeID)
        })
        dependencyReachability = DependencyReachabilityCache(
            adjacency: families.isEmpty ? [] : graph.dependencyAdjacency,
            candidates: candidateNodeIDs
        )
        guard isEager == false else {
            bufferedScopes = BufferedScopeCursor(enumerateEagerly(graph: graph, order: order))
            prepareNext()
            return
        }
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

    /// Counts every row the heap could emit, including ineligible promotions it would reject on selection.
    private static func rowCount(families: [Family], pivots: [Pivot]) -> Int {
        let familyRows = families.reduce(0) { total, family in
            let memberCount = family.members.count
            return total + memberCount * (memberCount - 1) / 2 + family.members.count(where: \.isActive) * memberCount
        }
        return familyRows + pivots.reduce(0) { $0 + $1.branches.count }
    }

    /// Emits the same stream as the merged heap: discovery order is the loop order, and priority order breaks benefit ties by that discovery order.
    ///
    /// Promotion eligibility queries containment before dependency reachability, as heap selection does, so the dependency cache sees the same searches.
    private mutating func enumerateEagerly(graph: ChoiceGraph, order: EnumerationOrder) -> [GraphTransformation] {
        var scopes: [(scope: ReplacementScope, benefit: Int)] = []
        for family in families {
            for firstIndex in family.members.indices {
                for secondIndex in (firstIndex + 1) ..< family.members.count {
                    let first = family.members[firstIndex]
                    let second = family.members[secondIndex]
                    let keepsFirst = first.size >= second.size
                    let target = keepsFirst ? first : second
                    let donor = keepsFirst ? second : first
                    let benefit = abs(first.size - second.size)
                    scopes.append((.selfSimilar(targetNodeID: target.nodeID, donorNodeID: donor.nodeID, sizeDelta: benefit), benefit))
                }
            }
        }
        for pivot in pivots {
            for branchID in pivot.branches {
                scopes.append((.branchPivot(pickNodeID: pivot.nodeID, targetBranchID: branchID), pivot.size))
            }
        }
        let targets = families.indices.flatMap { familyIndex in
            families[familyIndex].members.indices.compactMap { memberIndex -> (familyIndex: Int, memberIndex: Int)? in
                families[familyIndex].members[memberIndex].isActive ? (familyIndex, memberIndex) : nil
            }
        }.sorted { first, second in
            families[first.familyIndex].members[first.memberIndex].liveOrder < families[second.familyIndex].members[second.memberIndex].liveOrder
        }
        for (familyIndex, memberIndex) in targets {
            let target = families[familyIndex].members[memberIndex]
            for donor in families[familyIndex].members {
                let benefit = target.size - donor.size
                guard target.nodeID != donor.nodeID, donor.isActive, benefit > 0,
                      Self.isContainmentDescendant(donor.nodeID, of: target.nodeID, graph: graph)
                      || dependencyReachability.isReachable(from: target.nodeID, to: donor.nodeID)
                else {
                    continue
                }
                scopes.append((.descendantPromotion(ancestorPickNodeID: target.nodeID, descendantPickNodeID: donor.nodeID, sizeDelta: benefit), benefit))
            }
        }
        let ordered = switch order {
            case .discovery:
                scopes
            case .priority:
                scopes.enumerated().sorted { first, second in
                    if first.element.benefit != second.element.benefit {
                        return first.element.benefit > second.element.benefit
                    }
                    return first.offset < second.offset
                }.map(\.element)
        }
        return ordered.map { entry in
            GraphTransformation(
                operation: .replace(entry.scope),
                priority: DispatchPriority(structuralBenefit: entry.benefit, valueBenefit: 0, reductionMagnitude: 0, estimatedCost: 1)
            )
        }
    }

    /// Follows parent links, matching ``ContainmentIndex`` for the few promotions a small domain checks.
    private static func isContainmentDescendant(_ nodeID: Int, of ancestorNodeID: Int, graph: ChoiceGraph) -> Bool {
        var current = nodeID
        while let parent = graph.nodes[current].parent {
            if parent == ancestorNodeID {
                return true
            }
            current = parent
        }
        return false
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
                insert(.selfSimilar(PairRow(familyIndex: familyIndex, targetIndex: targetIndex, donorOrder: .size, nextDonor: 0, donorEnd: offset)))
                if family.members[targetIndex].isActive {
                    insert(.promotion(PairRow(familyIndex: familyIndex, targetIndex: targetIndex, donorOrder: .size, nextDonor: 0, donorEnd: smallerDonorCount)))
                }
            }
        }
    }

    /// Preserves family pair discovery and positional promotion order, filtering eligibility when each row is visited.
    private mutating func seedDiscoveryRows() {
        for (familyIndex, family) in families.enumerated() {
            for targetIndex in family.members.indices {
                insert(.selfSimilar(PairRow(familyIndex: familyIndex, targetIndex: targetIndex, donorOrder: .original, nextDonor: targetIndex + 1, donorEnd: family.members.count)))
                if family.members[targetIndex].isActive {
                    insert(.promotion(PairRow(familyIndex: familyIndex, targetIndex: targetIndex, donorOrder: .original, nextDonor: 0, donorEnd: family.members.count)))
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
                guard let donor = currentDonor(of: pair) else {
                    return
                }
                let target = families[pair.familyIndex].members[pair.targetIndex]
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
                guard let donor = currentDonor(of: pair) else {
                    return
                }
                let target = families[pair.familyIndex].members[pair.targetIndex]
                benefit = target.size - donor.size
                discoveryOrder = (2, target.liveOrder, donor.originalIndex, 0)
        }
        pendingRows.insert(Entry(
            row: row,
            benefit: benefit,
            discoveryOrder: discoveryOrder
        ))
    }

    /// Resolves the row's current donor, or nil once its donor positions are spent.
    private func currentDonor(of pair: PairRow) -> Member? {
        guard pair.nextDonor < pair.donorEnd else {
            return nil
        }
        let memberIndex = switch pair.donorOrder {
            case .size:
                families[pair.familyIndex].sizeOrder[pair.nextDonor]
            case .original:
                pair.nextDonor
        }
        return families[pair.familyIndex].members[memberIndex]
    }

    /// Advances only the selected row, skipping ineligible descendant promotions without buffering their scopes.
    private mutating func prepareNext() {
        guard bufferedScopes == nil else {
            pendingTransformation = bufferedScopes?.next()
            return
        }
        pendingTransformation = nil
        while let entry = pendingRows.popFirst() {
            let scope = scope(for: entry)
            switch entry.row {
                case var .selfSimilar(pair):
                    pair.nextDonor += 1
                    insert(.selfSimilar(pair))
                case let .pivot(pivotIndex, branchIndex):
                    insert(.pivot(pivotIndex: pivotIndex, branchIndex: branchIndex + 1))
                case var .promotion(pair):
                    pair.nextDonor += 1
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
    /// Inserted pair rows always have a current donor; exhaustion is rejected before a row enters the heap.
    private mutating func scope(for entry: Entry) -> ReplacementScope? {
        switch entry.row {
            case let .selfSimilar(pair):
                guard let second = currentDonor(of: pair) else {
                    return nil
                }
                let first = families[pair.familyIndex].members[pair.targetIndex]
                let keepsFirst = first.size > second.size || (first.size == second.size && first.originalIndex < second.originalIndex)
                let target = keepsFirst ? first : second
                let donor = keepsFirst ? second : first
                return .selfSimilar(targetNodeID: target.nodeID, donorNodeID: donor.nodeID, sizeDelta: entry.benefit)
            case let .pivot(pivotIndex, branchIndex):
                let pivot = pivots[pivotIndex]
                return .branchPivot(pickNodeID: pivot.nodeID, targetBranchID: pivot.branches[branchIndex])
            case let .promotion(pair):
                guard let donor = currentDonor(of: pair) else {
                    return nil
                }
                let target = families[pair.familyIndex].members[pair.targetIndex]
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
    var isValueDependent: Bool {
        false
    }

    var isPermutationSource: Bool {
        false
    }

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
