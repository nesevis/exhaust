/// Preserves shortest-first pivot order without retaining a complete sequence for every fill.
///
/// Preparation measures each recorded replacement span and keeps only IDs and resulting lengths. Fills retain discovery order within equal lengths: recorded, farthest when the recorded fill improves, then transplanted. Complete sequences and their hashes are built only while searching for the next uncached improving candidate. The graph snapshot and baseline must remain unchanged until this cursor is discarded after acceptance.
///
/// - Complexity: O(P log P) descriptor sorting and O(P) descriptors, in addition to the shared graph and baseline and one transient candidate. Measuring spans visits their flattened content. Enumeration can still inspect every fill when candidates fail ordering or are cached, but never retains their full-sequence cross product.
struct ImprovingPivotCandidateCursor {
    /// Carries the hash already checked against the pass's reject-cache snapshot.
    struct Probe {
        let sequence: ChoiceSequence
        let probeHash: UInt64
    }

    private struct Pivot {
        let pickNodeID: Int
        let targetBranchID: UInt64
        let candidateLength: Int
        let discoveryOrder: Int
    }

    private let sequence: ChoiceSequence
    private let graph: ChoiceGraph
    private let rejectCache: Set<UInt64>
    private let deadlineCheck: () -> Bool
    private let pivots: [Pivot]
    private var pivotIndex = 0
    private var fillIndex = 0
    private var isRecordedFillImproving = false

    var preparedPivotCount: Int {
        pivots.count
    }

    /// Counts complete sequences constructed, including those discarded by ordering or the cache, so preparation cost can be characterized independently of property probes.
    private(set) var constructedCandidateCount = 0

    /// Captures the cache at pass entry, preserving the eager pass's treatment of duplicate fills within that pass.
    init(sequence: ChoiceSequence, graph: ChoiceGraph, rejectCache: Set<UInt64>, deadlineCheck: @escaping () -> Bool = { false }) {
        self.sequence = sequence
        self.graph = graph
        self.rejectCache = rejectCache
        self.deadlineCheck = deadlineCheck
        guard deadlineCheck() == false else {
            pivots = []
            return
        }
        var prepared: [Pivot] = []
        var cursor = ReplacementQuery.pivotCursor(graph: graph)
        while deadlineCheck() == false, let transformation = cursor.next(lastAccepted: false) {
            guard case let .replace(.branchPivot(pickNodeID, targetBranchID)) = transformation.operation,
                  let splice = GraphStructuralEncoder.branchPivotSplice(
                      pickNodeID: pickNodeID,
                      targetBranchID: targetBranchID,
                      fill: .recorded,
                      graph: graph
                  )
            else {
                continue
            }
            let length = sequence.count - splice.range.count + splice.replacement.count
            guard length <= sequence.count else {
                continue
            }
            prepared.append(Pivot(
                pickNodeID: pickNodeID,
                targetBranchID: targetBranchID,
                candidateLength: length,
                discoveryOrder: prepared.count
            ))
        }
        pivots = prepared.sorted { first, second in
            if first.candidateLength != second.candidateLength {
                return first.candidateLength < second.candidateLength
            }
            return first.discoveryOrder < second.discoveryOrder
        }
    }

    /// Advances fill state before returning so cached recorded fills still enable their farthest fill, while non-improving recorded fills suppress it.
    private mutating func nextFill() -> PivotLeafFill? {
        let fill: PivotLeafFill? = switch fillIndex {
            case 0:
                .recorded
            case 1:
                isRecordedFillImproving ? .farthestFromTarget : nil
            default:
                .transplanted
        }
        fillIndex += 1
        return fill
    }
}

extension ImprovingPivotCandidateCursor: ScopeCursor {
    mutating func next(lastAccepted _: Bool) -> Probe? {
        while pivotIndex < pivots.count {
            guard deadlineCheck() == false else {
                pivotIndex = pivots.count
                return nil
            }
            if fillIndex == 3 {
                pivotIndex += 1
                fillIndex = 0
                isRecordedFillImproving = false
                continue
            }
            let pivot = pivots[pivotIndex]
            guard let fill = nextFill(),
                  let candidate = GraphStructuralEncoder.branchPivotCandidate(
                      pickNodeID: pivot.pickNodeID,
                      targetBranchID: pivot.targetBranchID,
                      fill: fill,
                      sequence: sequence,
                      graph: graph
                  )
            else {
                continue
            }
            constructedCandidateCount += 1
            let isImproving = pivot.candidateLength < sequence.count || candidate.shortLexPrecedes(sequence)
            if fill == .recorded {
                isRecordedFillImproving = isImproving
            }
            guard deadlineCheck() == false else {
                pivotIndex = pivots.count
                return nil
            }
            guard isImproving else {
                continue
            }
            let probeHash = ZobristHash.hash(of: candidate)
            guard deadlineCheck() == false else {
                pivotIndex = pivots.count
                return nil
            }
            guard rejectCache.contains(probeHash) == false else {
                continue
            }
            return Probe(sequence: candidate, probeHash: probeHash)
        }
        return nil
    }
}
