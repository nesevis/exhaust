//
//  ImprovingPivotCursor.swift
//  Exhaust
//

// MARK: - Improving Pivot Cursor

/// Yields branch pivots whose candidate precedes the baseline, shortest first, without retaining a complete sequence for every fill.
///
/// Preparation measures each recorded replacement span and keeps only IDs and resulting lengths. Pivots of equal length keep discovery order. Each pivot tries its fills in turn: recorded, then farthest from target when the recorded fill improves, then transplanted. Complete sequences and their hashes are built only while searching for the next uncached improving candidate. The graph snapshot and baseline must stay unchanged until this cursor is discarded after an acceptance.
///
/// - Complexity: O(P log P) descriptor sorting and O(P) descriptors, in addition to the shared graph and baseline and one transient candidate. Measuring spans visits their flattened content. Enumeration can still inspect every fill when candidates fail ordering or are cached, but never retains their full-sequence cross product.
struct ImprovingPivotCursor {
    /// A candidate with the hash already checked against the cache snapshot and every earlier probe.
    struct Probe {
        let sequence: ChoiceSequence
        let lookup: ProbeCache.Lookup
    }

    /// Every improving pivot uses exact decoding with picks materialized, standard decoder admission, and a strictly smaller recovered sequence.
    static let decision = ProbeDecision(isGuided: false, order: .strictlySmaller)

    private struct Pivot {
        let pickNodeID: Int
        let targetBranchID: UInt64
        let candidateLength: Int
        let discoveryOrder: Int
    }

    private let sequence: ChoiceSequence
    private let graph: ChoiceGraph
    private let rejectCache: ProbeCache
    private let incumbentHash: UInt64
    private let pivots: [Pivot]
    private var pivotIndex = 0
    private var fillIndex = 0
    private var isRecordedFillImproving = false
    /// Hashes of the probes already returned. Two fills can build the same sequence, and the cache snapshot does not learn of the first one's rejection.
    private var emittedHashes: Set<UInt64> = []

    /// Captures the cache at entry; probes returned since are skipped through ``emittedHashes``.
    /// - Parameter incumbentHash: The Zobrist hash of `sequence`.
    init(sequence: ChoiceSequence, incumbentHash: UInt64, graph: ChoiceGraph, rejectCache: ProbeCache, deadline: ReductionDeadline) {
        self.sequence = sequence
        self.incumbentHash = incumbentHash
        self.graph = graph
        self.rejectCache = rejectCache
        guard deadline.isExpired == false else {
            pivots = []
            return
        }
        var prepared: [Pivot] = []
        let source = ReplacementSource(pivotGraph: graph)
        while deadline.isExpired == false, let priced = source.nextScope() {
            guard case let .branchPivot(scope) = priced.encoderScope,
                  let splice = PivotCandidates.branchPivotSplice(
                      pickNodeID: scope.pickNodeID,
                      targetBranchID: scope.targetBranchID,
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
                pickNodeID: scope.pickNodeID,
                targetBranchID: scope.targetBranchID,
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

    mutating func next() -> Probe? {
        while pivotIndex < pivots.count {
            // Three fills per pivot: recorded, farthest from target, transplanted.
            if fillIndex == 3 {
                pivotIndex += 1
                fillIndex = 0
                isRecordedFillImproving = false
                continue
            }
            let pivot = pivots[pivotIndex]
            guard let fill = nextFill(),
                  let candidate = PivotCandidates.branchPivotCandidate(
                      pickNodeID: pivot.pickNodeID,
                      targetBranchID: pivot.targetBranchID,
                      fill: fill,
                      sequence: sequence,
                      graph: graph
                  )
            else {
                continue
            }
            let isImproving = pivot.candidateLength < sequence.count || candidate.shortLexPrecedes(sequence)
            if fill == .recorded {
                isRecordedFillImproving = isImproving
            }
            guard isImproving else {
                continue
            }
            let probeHash = ZobristHash.hash(of: candidate)
            let lookup = rejectCache.lookup(probeHash: probeHash, decision: Self.decision, incumbentHash: incumbentHash)
            guard lookup.isCached == false, emittedHashes.insert(probeHash).inserted else {
                continue
            }
            return Probe(sequence: candidate, lookup: lookup)
        }
        return nil
    }

    // MARK: - Helpers

    /// Advances fill state before returning, so a cached recorded fill still enables its farthest fill while a non-improving one suppresses it.
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
