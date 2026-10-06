/// Ranks structural perturbations by length while deferring complete candidate construction until probing.
///
/// Length ties preserve replacement discovery order. Preparation visits every scope because even a late scope can enter the shortest prefix, but retains only the materialization budget's worth of splices. Donor expansion and exact no-op classification are cached per node rather than repeated per pair. The temporary content cache can contain the sum of participating subtree sizes; after preparation, only selected replacement spans and the baseline remain.
struct RelaxCandidateCursor {
    private let sequence: ChoiceSequence
    private var splices: BufferedScopeCursor<ChoiceSequenceSplice>

    /// Counts all valid perturbations, including those outside the budget, to preserve relax diagnostics.
    let candidateCount: Int
    let retainedCandidateCount: Int

    init(sequence: ChoiceSequence, graph: ChoiceGraph, limit: Int) {
        self.sequence = sequence
        var cache = ContentCache()
        var selected = BoundedSortedBuffer<ChoiceSequenceSplice>(limit: limit)
        var count = 0
        var cursor = ReplacementQuery.discoveryCursor(graph: graph)
        while let transformation = cursor.next(lastAccepted: false) {
            guard case let .replace(scope) = transformation.operation,
                  let splice = cache.splice(for: scope, sequence: sequence, graph: graph)
            else {
                continue
            }
            count += 1
            // The shared baseline contributes the same length to every candidate. Length ties deliberately retain discovery order: a shortlex tiebreak can prefer a perturbation that triggers a full exploitation loop where the prior ordering ended cheaply at perturbation.
            selected.insert(splice) { first, second in
                first.replacement.count - first.range.count < second.replacement.count - second.range.count
            }
        }
        candidateCount = count
        retainedCandidateCount = selected.elements.count
        splices = BufferedScopeCursor(selected.elements)
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

    /// Interns raw and expanded subtree content once per node, making repeated pair no-op checks constant time.
    private struct ContentCache {
        var identities: [Content: Int] = [:]
        var contents: [ChoiceSequence] = []
        var rawIdentityByNodeID: [Int: Int] = [:]
        var expandedIdentityByNodeID: [Int: Int] = [:]

        /// Shares donor storage across the bounded set and rejects unchanged substitutions without copying the baseline.
        mutating func splice(for scope: ReplacementScope, sequence: ChoiceSequence, graph: ChoiceGraph) -> ChoiceSequenceSplice? {
            switch scope {
                case let .branchPivot(pickNodeID, targetBranchID):
                    return GraphStructuralEncoder.branchPivotSplice(pickNodeID: pickNodeID, targetBranchID: targetBranchID, graph: graph)
                case let .selfSimilar(targetNodeID, donorNodeID, _),
                     let .descendantPromotion(targetNodeID, donorNodeID, _):
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
                    return ChoiceSequenceSplice(range: targetRange, replacement: contents[donorIdentity])
            }
        }

        /// Expands each donor once even if it is proposed for many different targets.
        private mutating func expandedIdentity(nodeID: Int, range: ClosedRange<Int>, sequence: ChoiceSequence, graph: ChoiceGraph) -> Int {
            if let identity = expandedIdentityByNodeID[nodeID] {
                return identity
            }
            let expanded = GraphStructuralEncoder.expandDepthZeroLeaves(
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

extension RelaxCandidateCursor: ScopeCursor {
    mutating func next(lastAccepted: Bool) -> ChoiceSequence? {
        splices.next(lastAccepted: lastAccepted)?.applying(to: sequence)
    }
}
