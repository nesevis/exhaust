//
//  RelaxCandidateCursor.swift
//  Exhaust
//

// MARK: - Relax Candidate Cursor

/// Ranks structural perturbations by length while deferring complete candidate construction until probing.
///
/// Length ties keep replacement discovery order. Preparation visits every scope because even a late scope can enter the shortest prefix, but retains only the materialization budget's worth of splices. A splice that writes the same content over the same range as a retained one is dropped, so duplicates cannot spend the budget. Checking the retained prefix alone suffices: equal splices rank equally and ties keep discovery order, so a later duplicate of a discarded splice is discarded too. Donor expansion and exact no-op classification are cached per node rather than repeated per pair. The temporary content cache can hold the sum of participating subtree sizes; after preparation, only the selected replacement spans and the baseline remain.
struct RelaxCandidateCursor {
    private let sequence: ChoiceSequence
    private var splices: BufferedScopeCursor<ChoiceSequenceSplice>

    /// Counts every valid perturbation, including those outside the budget and duplicates of discarded ones, for relax diagnostics.
    let candidateCount: Int

    /// Rejects disabled operations before splice preparation and ranking, so they cannot displace enabled candidates from the retained prefix.
    init(sequence: ChoiceSequence, graph: ChoiceGraph, limit: Int, isEncoderEnabled: (EncoderName) -> Bool = { _ in true }) {
        self.sequence = sequence
        guard isEncoderEnabled(.branchPivot) || isEncoderEnabled(.substitution) else {
            candidateCount = 0
            splices = BufferedScopeCursor([])
            return
        }
        var cache = ContentCache()
        var selected = BoundedSortedBuffer<KeyedSplice>(limit: limit)
        var count = 0
        let source = isEncoderEnabled(.substitution)
            ? ReplacementSource(graph: graph, order: .discovery)
            : ReplacementSource(pivotGraph: graph)
        while let priced = source.nextScope() {
            guard isEncoderEnabled(priced.encoderScope.encoder.name),
                  case let (splice, contentIdentity)? = cache.splice(for: priced.encoderScope, sequence: sequence, graph: graph)
            else {
                continue
            }
            count += 1
            let key = SpliceKey(range: splice.range, contentIdentity: contentIdentity)
            guard selected.elements.contains(where: { $0.key == key }) == false else {
                continue
            }
            // The shared baseline contributes the same length to every candidate. Length ties keep discovery order: a shortlex tiebreak can select a perturbation that triggers a full exploitation loop, where the discovery-order choice ends cheaply at perturbation.
            selected.insert(KeyedSplice(splice: splice, key: key)) { first, second in
                first.splice.replacement.count - first.splice.range.count < second.splice.replacement.count - second.splice.range.count
            }
        }
        candidateCount = count
        splices = BufferedScopeCursor(selected.elements.map(\.splice))
    }

    mutating func next() -> ChoiceSequence? {
        splices.next()?.applying(to: sequence)
    }

    // MARK: - Helpers

    /// Two splices with equal keys build the same candidate.
    private struct SpliceKey: Hashable {
        let range: ClosedRange<Int>
        let contentIdentity: Int
    }

    private struct KeyedSplice {
        let splice: ChoiceSequenceSplice
        let key: SpliceKey
    }

    /// Uses the operative hash only for bucketing; equality checks complete entries, including structural metadata.
    private struct Content: Hashable {
        let entries: ChoiceSequence
        let hash: UInt64

        init(_ entries: ChoiceSequence) {
            self.entries = entries
            hash = entries.operativeHash
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.entries == rhs.entries
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(hash)
        }
    }

    /// Interns raw and expanded subtree content once per node, making repeated no-op checks constant time.
    private struct ContentCache {
        var identities: [Content: Int] = [:]
        var contents: [ChoiceSequence] = []
        var rawIdentityByNodeID: [Int: Int] = [:]
        var expandedIdentityByNodeID: [Int: Int] = [:]

        /// Shares donor storage across the bounded set and rejects unchanged substitutions without copying the baseline. Returns the replacement's interned identity alongside the splice.
        mutating func splice(for encoderScope: AnyEncoderScope, sequence: ChoiceSequence, graph: ChoiceGraph) -> (ChoiceSequenceSplice, Int)? {
            let targetNodeID: Int
            let donorNodeID: Int
            switch encoderScope {
                case let .branchPivot(scope):
                    guard let splice = PivotCandidates.branchPivotSplice(
                        pickNodeID: scope.pickNodeID,
                        targetBranchID: scope.targetBranchID,
                        graph: graph
                    ) else {
                        return nil
                    }
                    return (splice, intern(splice.replacement))
                case let .substitution(.selfSimilar(target, donor)):
                    targetNodeID = target
                    donorNodeID = donor
                case let .substitution(.descendantPromotion(ancestor, descendant)):
                    targetNodeID = ancestor
                    donorNodeID = descendant
                default:
                    return nil
            }
            guard let targetRange = graph.nodes[targetNodeID].positionRange,
                  let donorRange = graph.nodes[donorNodeID].positionRange
            else {
                return nil
            }
            let donorIdentity = expandedIdentity(nodeID: donorNodeID, range: donorRange, sequence: sequence, graph: graph)
            if contents[donorIdentity].count == targetRange.count,
               donorIdentity == rawIdentity(nodeID: targetNodeID, range: targetRange, sequence: sequence)
            {
                return nil
            }
            return (ChoiceSequenceSplice(range: targetRange, replacement: contents[donorIdentity]), donorIdentity)
        }

        /// Expands each donor once even if it is proposed for many targets.
        private mutating func expandedIdentity(nodeID: Int, range: ClosedRange<Int>, sequence: ChoiceSequence, graph: ChoiceGraph) -> Int {
            if let identity = expandedIdentityByNodeID[nodeID] {
                return identity
            }
            let expanded = PivotCandidates.expandDepthZeroLeaves(
                Array(sequence[range]),
                donorNodeID: nodeID,
                donorRangeStart: range.lowerBound,
                graph: graph
            )
            let identity = intern(ChoiceSequence(expanded))
            expandedIdentityByNodeID[nodeID] = identity
            return identity
        }

        private mutating func rawIdentity(nodeID: Int, range: ClosedRange<Int>, sequence: ChoiceSequence) -> Int {
            if let identity = rawIdentityByNodeID[nodeID] {
                return identity
            }
            let identity = intern(ChoiceSequence(sequence[range]))
            rawIdentityByNodeID[nodeID] = identity
            return identity
        }

        private mutating func intern(_ entries: ChoiceSequence) -> Int {
            let content = Content(entries)
            if let identity = identities[content] {
                return identity
            }
            let identity = contents.count
            contents.append(entries)
            identities[content] = identity
            return identity
        }
    }
}
