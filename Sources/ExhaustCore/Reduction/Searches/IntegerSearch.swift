//
//  IntegerSearch.swift
//  Exhaust
//

// MARK: - Integer Search

/// Drives integer leaves toward their semantic simplest values without changing graph structure.
///
/// Runs four phases, cheapest first: batch zero, per-leaf zero, batch bisection, and per-leaf search. Per-leaf search probes the target directly, then runs ``InterpolationSearchStepper`` (binary search below ``ReductionTuning/interpolationBinaryThreshold``). After it converges, a small non-monotone gap is scanned linearly, a character leaf tries its simpler forms, and a signed leaf tries values across zero that bit-pattern search cannot reach.
///
/// All leaves have position ranges in the current sequence. Candidates are constructed by modifying leaf values at pre-resolved positions, and an acceptance advances the baseline to the accepted candidate.
///
/// The phases live in `IntegerSearch+Probing.swift`.
struct IntegerSearch: ReductionSearch {
    // MARK: - State

    var state: State

    // MARK: - Leaf Position

    /// Metadata for a single integer leaf under value search.
    struct LeafPosition: LeafMutationSource {
        let nodeID: Int
        let sequenceIndex: Int
        var currentBitPattern: UInt64
        let targetBitPattern: UInt64
        let typeTag: TypeTag
        let mayReshape: Bool
        /// Simpler forms of the leaf's character, or nil when the leaf is not a character.
        let characterSimplifications: CharacterSimplifications?
    }

    // MARK: - Phase State

    /// Everything the search carries between pulls: its tuning limits, its position across its phases, and the convergence records it has gathered. The phases are static functions over this state, so a pull edits it in place. At most one of ``crossZero``, ``candidateList``, and ``stepper`` is active for the current leaf.
    struct State {
        // Limits from ``ReductionTuning``, fixed for the search.
        let linearScanThreshold: UInt64
        let bisectionInitialDivisor: UInt64
        let bisectionBinaryThreshold: UInt64
        let interpolationBinaryThreshold: UInt64
        let interpolationInitialDivisor: UInt64
        var sequence: ChoiceSequence
        var leafPositions: [LeafPosition]
        var phase: Phase
        var leafIndex: Int
        var stepper: DirectionalStepper?
        var warmStartRecords: [Int: ConvergedOrigin]
        /// Whether the batch-zero probe was rejected. When true and a leaf individually converges at its target, the convergence signal is `zeroingDependency` instead of `monotoneConvergence`.
        var batchRejected: Bool
        /// Candidates that binary search cannot reach for the current leaf, or nil when inactive. Set when binary search converges.
        var candidateList: CandidateListState?
        /// Cross-zero phase state for the current leaf, or nil when inactive. Set after binary search (and any linear scan recovery) converges on a signed-type leaf whose current shortlex key permits crossing zero.
        var crossZero: CrossZeroState?
        /// Batch bisection state, active during the ``Phase/batchBisect`` phase.
        var bisection: BisectionState?
        /// Whether the reduction target has been probed directly for the current leaf. Reset when advancing to the next leaf.
        var semanticSimplestProbed: Bool = false
        /// Per-leaf-zero pre-round state, active during the ``Phase/perLeafZero`` phase.
        var perLeafZero: PerLeafZeroState?
        /// Convergence records keyed by graph node ID, which ``IntegerSearch/finish(pending:)`` reports.
        var convergenceStore: [Int: ConvergedOrigin] = [:]
    }

    /// Where the candidates came from, which decides when the list ends and how its convergence is recorded.
    enum CandidateListSource: Equatable {
        /// Every bit pattern in a non-monotone gap of at most ``ReductionTuning/valueLinearScanThreshold`` below the converged bound. Scanning continues past acceptances, and exhaustion records a `.scanComplete` convergence before trying cross-zero.
        case gapScan
        /// Simpler forms of a character leaf's current character, from ``CharacterSimplifications``. Ascending order makes the first acceptance the simplest reachable form, so it ends the list. The accepted index replaces the bound of the binary search record, so a warm start on the next pass does not search again.
        case characterSimplification

        var endsOnFirstAcceptance: Bool {
            switch self {
                case .gapScan:
                    false
                case .characterSimplification:
                    true
            }
        }
    }

    /// Bit patterns below the converged bound that binary search cannot reach, probed one at a time in ascending order.
    ///
    /// Candidates that do not shortlex-precede the current entry are skipped without a probe. ``bestAccepted`` is the lowest accepted candidate, which the finish step records as the leaf's convergence bound.
    struct CandidateListState {
        let source: CandidateListSource
        let candidates: ArraySlice<UInt64>
        /// Index into ``candidates`` of the next candidate to consider. The candidate before it is the outstanding probe once any probe has been emitted.
        var nextIndex: Int
        var bestAccepted: UInt64?

        init(source: CandidateListSource, candidates: ArraySlice<UInt64>) {
            self.source = source
            self.candidates = candidates
            nextIndex = candidates.startIndex
            bestAccepted = nil
        }

        /// Folds the outstanding probe's acceptance into ``bestAccepted``. Returns false when no probe has been emitted.
        @discardableResult
        mutating func recordOutstandingAcceptance() -> Bool {
            guard nextIndex > candidates.startIndex else {
                return false
            }
            let acceptedValue = candidates[nextIndex - 1]
            bestAccepted = min(bestAccepted ?? acceptedValue, acceptedValue)
            return true
        }
    }

    /// State for the cross-zero phase of per-leaf minimization.
    ///
    /// After bit-pattern binary search converges on one side of zero for a signed type, this phase enumerates shortlex keys from the simplest (key 0 ↔ value 0) upward. Each key decodes via ``ChoiceValue/fromShortlexKey(_:tag:)`` to a signed value on the opposite side of zero from the current convergence, closing the gap that bit-pattern binary search cannot bridge (for example, reducing value `1` to value `0` or `-1`).
    ///
    /// The walk climbs from key 0, so the first accepted probe is the simplest value this phase can reach and any later acceptance would be less simple. The phase therefore exits on its first acceptance.
    struct CrossZeroState {
        let sequenceIndex: Int
        let tag: TypeTag
        let validRange: ClosedRange<UInt64>?
        let isRangeExplicit: Bool
        /// The next shortlex key to probe.
        var nextKey: UInt64
        /// Exclusive upper bound on the key walk. Equals `min(initialCurrentKey, adaptiveBudget)`.
        let endKey: UInt64
        /// The shortlex key of the last emitted probe, or `nil` when no probe has been emitted yet (or after feedback has been consumed).
        var lastEmittedKey: UInt64?
    }

    /// Sub-phases of integer reduction, ordered from cheapest to most granular: batch zero tries all leaves at once, per-leaf zero probes each individually, batch bisect does group interpolation search, and per-leaf runs individual interpolation or binary search.
    enum Phase {
        case batchZero
        case perLeafZero
        case batchBisect
        case perLeaf
    }

    /// State for the per-leaf-zero pre-round.
    struct PerLeafZeroState {
        var leafCursor: Int = 0
        var convergedIndices: Set<Int> = []
    }

    /// State for the batch bisection phase.
    ///
    /// Searches groups of leaves jointly. Each probe moves every unconverged leaf in the group to `1 / divisor` of its remaining distance from its target. An acceptance updates the group's values and resets the divisor. A rejection halves the divisor, and once the divisor reaches ``ReductionTuning/valueBisectionBinaryThreshold`` the group splits into two halves searched independently. Single-leaf groups are left to the per-leaf phase.
    struct BisectionState {
        /// Stack of leaf groups to search. Each group is a half-open interval into ``State/leafPositions``.
        var pendingGroups: [(start: Int, end: Int)]
        /// The group currently being searched. Nil when no group is active, so the next pending group is popped.
        var activeGroup: (start: Int, end: Int)?
        /// Current interpolation divisor for the active group. Halves on rejection, resets to ``ReductionTuning/valueBisectionInitialDivisor`` on acceptance.
        var divisor: UInt64
        /// Whether a probe for the active group is awaiting feedback.
        var awaitingFeedback: Bool
        /// Leaf indices that were accepted during bisection and should be skipped in per-leaf phase.
        var convergedIndices: Set<Int>
    }

    /// Directional search stepper for bit-pattern-space search.
    ///
    /// Uses interpolation search for large ranges and plain binary search for small ranges. The threshold is ``ReductionTuning/interpolationBinaryThreshold``.
    ///
    /// Exactly one of `binary` or `interpolation` is non-nil at any time. The flat-optional layout avoids the overhead of enum associated-value extraction and reconstruction on every call to ``advance(lastAccepted:)``, which sits on the reducer's tightest per-iteration loop.
    struct DirectionalStepper {
        private var binary: BinarySearchStepper?
        private var interpolation: InterpolationSearchStepper?

        var bestAccepted: UInt64 {
            binary?.bestAccepted ?? interpolation?.bestAccepted ?? 0
        }

        var resumeBound: UInt64 {
            binary?.resumeBound ?? interpolation?.resumeBound ?? 0
        }

        init(binary stepper: BinarySearchStepper) {
            binary = stepper
        }

        init(interpolation stepper: InterpolationSearchStepper) {
            interpolation = stepper
        }

        mutating func start() -> UInt64? {
            if binary != nil {
                return binary!.start()
            } else if interpolation != nil {
                return interpolation!.start()
            }
            return nil
        }

        mutating func advance(lastAccepted: Bool) -> UInt64? {
            if binary != nil {
                return binary!.advance(lastAccepted: lastAccepted)
            } else if interpolation != nil {
                return interpolation!.advance(lastAccepted: lastAccepted)
            }
            return nil
        }
    }

    // MARK: - Search

    /// Starts on `scope` over `sequence`, warm-starting from `warmStarts`, keyed by node ID, and reading its scan, bisection, and interpolation limits from `tuning`.
    init(
        scope: ValueMinimizationScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph,
        warmStarts: [Int: ConvergedOrigin],
        tuning: ReductionTuning
    ) {
        state = Self.initialState(scope: scope, sequence: sequence, graph: graph, warmStarts: warmStarts, tuning: tuning)
    }

    mutating func next(_ feedback: SearchFeedback, into buffer: inout ChoiceSequence) -> ReductionCandidate? {
        if case let .accepted(recovered) = feedback {
            // Leaf positions were resolved against the dispatch-time sequence, so a recovered sequence of a different length ends the search.
            guard recovered.count == state.sequence.count else {
                return nil
            }
            state.sequence = recovered
        }
        guard let built = Self.nextProbe(state: &state, lastAccepted: feedback.isAccepted) else {
            return nil
        }
        buffer = built
        let mutation = state.leafPositions.leafValuesMutation(candidate: buffer, baseline: state.sequence)
        return .written(mutation: mutation, admission: .standard)
    }

    /// Reports the convergence records gathered so far, first recording the progress of the leaf in progress so its search resumes from there on the next dispatch.
    consuming func finish(pending: SearchFeedback) -> SearchReport {
        flushPartialConvergence(pendingAccepted: pending.isAccepted)
        return SearchReport(convergenceRecords: state.convergenceStore)
    }

    /// Records the in-progress leaf's progress, which each per-leaf phase otherwise records only when it completes. Without this, the progress is lost and the search restarts from the previous record on the next dispatch.
    ///
    /// A pending acceptance belongs to the outstanding probe of whichever phase is active, checked in the per-leaf loop's order: cross-zero, then the candidate list, then the stepper. Cross-zero and the candidate list learn of an acceptance only when they are next pulled, so the acceptance is delivered to them here first. A stepper records its ``DirectionalStepper/resumeBound``, which an acceptance never moves: every reader of a record treats its bound as a floor, so an accepted value, below which nothing has been tried, must not be recorded.
    private mutating func flushPartialConvergence(pendingAccepted: Bool) {
        guard state.leafIndex < state.leafPositions.count else {
            return
        }
        let leaf = state.leafPositions[state.leafIndex]
        if let crossZero = state.crossZero {
            if pendingAccepted, let acceptedKey = crossZero.lastEmittedKey {
                state.recordCrossZeroAcceptance(acceptedKey, tag: crossZero.tag, nodeID: leaf.nodeID)
            }
            return
        }
        if var list = state.candidateList {
            if pendingAccepted {
                list.recordOutstandingAcceptance()
            }
            // An unfinished scan is not complete, so the record keeps its binary search configuration. The next dispatch warm-starts at the lowered bound and scans the gap below it again.
            if let bestAccepted = list.bestAccepted {
                state.lowerRecordedBound(to: bestAccepted, nodeID: leaf.nodeID)
            }
            return
        }
        guard state.convergenceStore[leaf.nodeID] == nil else {
            return
        }
        guard let resumeBound = state.stepper?.resumeBound else {
            return
        }
        state.convergenceStore[leaf.nodeID] = ConvergedOrigin(
            bound: resumeBound,
            signal: .monotoneConvergence,
            configuration: .binarySearchSemanticSimplest,
            cycle: 0
        )
    }
}
