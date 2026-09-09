//
//  GraphBindPivotEncoder.swift
//  Exhaust
//

/// Pivots a pick inside a bind's inner subtree, regenerates the bound subtree, and enumerates the regenerated subtree's leaves for a failing assignment.
///
/// A plain branch pivot on such a pick decodes the bound subtree in guided mode, which keeps every previous leaf value the new ranges still admit. That is the wrong assignment whenever the failure depends on a value the previous inner had pinned: a leaf whose range was a singleton under the old inner keeps its old value under the new one, although the widened range is exactly where the failing value lies. Bound value search would find it, but its upstream is a numeric search over a `chooseBits` leaf and a pick-shaped inner is unclassifiable to it. This encoder is the structural counterpart: one lift per scope, then the same covering enumeration over the bound subtree that the bound value composition runs downstream.
///
/// ## Probe sequence
///
/// 1. ``start(scope:)`` builds the pivot candidate as ``GraphStructuralEncoder`` does, with the target branch's leaves at their reduction targets. When the bound subtree is a pick, one further seed per same-fingerprint descendant of that pick puts the descendant's span in the bound subtree's place: the new inner may make the bound subtree's current shape invalid while a subtree below it is exactly what the site now wants, which a guided lift alone would replace with fallback content rather than promote.
/// 2. Each seed is lifted through the generator. The lift is a full guided materialization, so the bound subtree comes out regenerated for the new inner wherever the seed does not already fit it.
/// 3. The lifted sequence must not be longer than the base sequence. A pivot that lengthens the sequence cannot be admitted, and the covering search would only be rearranging values inside a candidate that is already lost.
/// 4. The lifted sequence itself is the seed's first probe: a bound subtree without ranged leaves has nothing to enumerate, and a transplant is a candidate in its own right. ``BoundValueCoveringEncoder`` is then started on the lifted sequence over the bound subtree's position range. Small domains are enumerated exhaustively, larger ones pairwise, exactly as downstream of the bound value composition. A single leaf with a domain too large for exhaustive enumeration gets no covering rows, so that case is probed at both ends of its range instead: the values just above the lower bound and just below the upper bound, up to ``coveringBudget`` in all, since a range the new inner has just widened fails at its edges when it fails at all. Seeds are consumed in order as each covering runs dry.
/// 5. Every probe carries the pivot as its mutation, so acceptance rebuilds the graph from the fresh tree. The regenerated bound subtree is in the candidate sequence; the mutation only has to name the pick.
///
/// The encoder does not know the generator; the scheduler supplies ``lift`` at dispatch time.
///
/// Probes go through the guided decoder, not the exact one, although every candidate is a complete lifted sequence. Guided resolution takes each coordinate from the prefix first and consults the fallback tree only where the prefix does not fit, and a complete lifted sequence fits everywhere, so the pre-pivot tree is never read. Exact decoding was measured to reject a share of lifted candidates that guided decoding accepts as genuine failures, so routing these probes as stateful would lose reductions. Acceptance rebuilds the graph and ends the session, so no state survives an accepted probe and nothing needs refreshing.
struct GraphBindPivotEncoder: GraphEncoder {
    typealias Lift = (_ candidate: ChoiceSequence, _ fallbackTree: ChoiceTree) -> ChoiceTree?

    let name: EncoderName = .bindPivot

    /// Descendant transplants tried per scope beyond the plain pivot, smallest first. Each costs one lift materialization before any probe is emitted.
    static let maxTransplants = 4

    /// Probes spent on a single large-domain leaf, split between the two ends of its range.
    static let coveringBudget = BoundValueCoveringEncoder.coveringBudget

    private let lift: Lift
    private var covering = BoundValueCoveringEncoder()
    private var edgeProbes: [ChoiceSequence] = []
    private var liftedProbe: ChoiceSequence?
    private var active = false
    private var mutation: ProjectedMutation?
    private var seeds: [ChoiceSequence] = []
    private var bindNodeID = -1
    private var baseCount = 0
    private var fallbackTree: ChoiceTree?

    init(lift: @escaping Lift) {
        self.lift = lift
    }

    mutating func start(scope: EncoderInput) {
        active = false
        mutation = nil
        seeds = []
        edgeProbes = []
        liftedProbe = nil

        guard case let .minimize(.bindPivot(pivotScope)) = scope.transformation.operation else { return }
        let graph = scope.graph
        guard pivotScope.bindNodeID < graph.nodes.count,
              case let .bind(bindMetadata) = graph.nodes[pivotScope.bindNodeID].kind,
              graph.nodes[pivotScope.bindNodeID].children.count > bindMetadata.boundChildIndex,
              let pickRange = graph.nodes[pivotScope.pickNodeID].positionRange,
              let pivotCandidate = GraphStructuralEncoder.branchPivotCandidate(
                  pickNodeID: pivotScope.pickNodeID,
                  targetBranchID: pivotScope.targetBranchID,
                  sequence: scope.baseSequence,
                  graph: graph
              )
        else { return }

        bindNodeID = pivotScope.bindNodeID
        baseCount = scope.baseSequence.count
        fallbackTree = scope.tree
        mutation = .branchSelected(pickNodeID: pivotScope.pickNodeID, newSelectedID: pivotScope.targetBranchID)
        seeds = [pivotCandidate]

        let boundChildID = graph.nodes[pivotScope.bindNodeID].children[bindMetadata.boundChildIndex]
        if let boundRange = graph.nodes[boundChildID].positionRange, boundRange.lowerBound > pickRange.upperBound {
            let shift = pivotCandidate.count - scope.baseSequence.count
            let shiftedBoundRange = (boundRange.lowerBound + shift) ... (boundRange.upperBound + shift)
            for descendantID in Self.transplantDonors(boundChildID: boundChildID, boundRange: boundRange, graph: graph) {
                guard let donorRange = graph.nodes[descendantID].positionRange else { continue }
                let expanded = GraphStructuralEncoder.expandDepthZeroLeaves(
                    Array(scope.baseSequence[donorRange.lowerBound ... donorRange.upperBound]),
                    donorNodeID: descendantID,
                    donorRangeStart: donorRange.lowerBound,
                    graph: graph
                )
                var seed = pivotCandidate
                seed.replaceSubrange(shiftedBoundRange, with: expanded)
                seeds.append(seed)
            }
        }
    }

    mutating func nextProbe(into candidate: inout ChoiceSequence, lastAccepted: Bool) -> EncoderProbe? {
        guard let mutation else { return nil }
        while true {
            if active {
                if let lifted = liftedProbe {
                    liftedProbe = nil
                    candidate = lifted
                    return mutation
                }
                if let built = covering.nextProbe(lastAccepted: lastAccepted) {
                    candidate = built
                    return mutation
                }
                if edgeProbes.isEmpty == false {
                    candidate = edgeProbes.removeFirst()
                    return mutation
                }
                active = false
            }
            guard seeds.isEmpty == false else { return nil }
            let seed = seeds.removeFirst()
            if startCovering(seed: seed) {
                active = true
            }
        }
    }

    /// Lifts `seed` through the generator and starts the covering search over the lifted bound subtree. False when the lift fails, the lifted sequence is longer than the base, or the bind cannot be located in the lifted graph.
    private mutating func startCovering(seed: ChoiceSequence) -> Bool {
        guard let fallbackTree, let freshTree = lift(seed, fallbackTree) else {
            return false
        }
        // A lift that comes out longer is dropped without flagging a shortlex rejection: the relax round exploits replacement candidates, and a regenerated bound subtree is not one.
        let lifted = ChoiceSequence(freshTree)
        guard lifted.count <= baseCount else { return false }

        // The bind precedes its own subtree in the build order, so its node ID is the same in the lifted graph as long as nothing before the bind changed, which the pivot inside the bind guarantees.
        let liftedGraph = ChoiceGraph.build(from: freshTree)
        guard bindNodeID < liftedGraph.nodes.count,
              case let .bind(metadata) = liftedGraph.nodes[bindNodeID].kind,
              liftedGraph.nodes[bindNodeID].children.count > metadata.boundChildIndex,
              let boundRange = liftedGraph.nodes[liftedGraph.nodes[bindNodeID].children[metadata.boundChildIndex]].positionRange
        else { return false }

        liftedProbe = lifted
        covering.start(sequence: lifted, tree: freshTree, positionRange: boundRange)
        edgeProbes = Self.edgeProbes(in: lifted, range: boundRange)
        return true
    }

    /// Candidates for a bound subtree whose only ranged leaf has more values than the covering enumerates. Alternates the lowest and highest values of the range, low end first, skipping the value already in place. Empty when the subtree has no such single leaf.
    private static func edgeProbes(in sequence: ChoiceSequence, range: ClosedRange<Int>) -> [ChoiceSequence] {
        var positions: [Int] = []
        for index in range where index < sequence.count {
            if let value = sequence[index].value, value.validRange != nil {
                positions.append(index)
            }
        }
        guard positions.count == 1,
              let value = sequence[positions[0]].value,
              let validRange = value.validRange,
              validRange.saturatingCount > BoundValueCoveringEncoder.exhaustiveThreshold
        else { return [] }

        let position = positions[0]
        let current = value.choice.bitPattern64
        var probes: [ChoiceSequence] = []
        var step: UInt64 = 0
        while probes.count < coveringBudget {
            let low = validRange.lowerBound &+ step
            let high = validRange.upperBound &- step
            guard low <= high else { break }
            for bitPattern in low == high ? [low] : [low, high] where bitPattern != current && probes.count < coveringBudget {
                var candidate = sequence
                candidate[position] = .value(.init(
                    choice: ChoiceValue(value.choice.tag.makeConvertible(bitPattern64: bitPattern), tag: value.choice.tag),
                    validRange: validRange,
                    isRangeExplicit: value.isRangeExplicit
                ))
                probes.append(candidate)
            }
            step &+= 1
        }
        return probes
    }

    /// Active picks below `boundChildID` sharing its fingerprint, smallest span first, at most ``maxTransplants``. Empty when the bound subtree is not a pick: only a pick's span can stand in for another pick of the same family.
    private static func transplantDonors(
        boundChildID: Int,
        boundRange: ClosedRange<Int>,
        graph: ChoiceGraph
    ) -> [Int] {
        guard case let .pick(metadata) = graph.nodes[boundChildID].kind,
              let group = graph.selfSimilarityGroups[metadata.fingerprint]
        else { return [] }
        let donors = group.filter { candidateID in
            guard candidateID != boundChildID,
                  let range = graph.nodes[candidateID].positionRange
            else { return false }
            return range.lowerBound > boundRange.lowerBound && range.upperBound <= boundRange.upperBound
        }
        let sorted = donors.sorted { lhs, rhs in
            (graph.nodes[lhs].positionRange?.count ?? 0) < (graph.nodes[rhs].positionRange?.count ?? 0)
        }
        return Array(sorted.prefix(maxTransplants))
    }
}
