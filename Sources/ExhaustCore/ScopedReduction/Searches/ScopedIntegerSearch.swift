//
//  ScopedIntegerSearch.swift
//  Exhaust
//

// MARK: - Integer Search

/// Drives integer leaves toward their semantic simplest without changing graph structure: a batch zeroing attempt followed by per-leaf interpolation search via ``InterpolationSearchStepper`` (falling back to binary search below a threshold), with a cross-zero phase for signed integers.
///
/// All leaves have position ranges in the current sequence. Candidates are constructed by modifying leaf values at pre-resolved positions, and an acceptance advances the baseline to the accepted candidate.
///
/// The phases live in `ScopedIntegerSearch+Probing.swift`.
struct ScopedIntegerSearch: ScopedSearch {
    // MARK: - State

    var state: State
    let linearScanThreshold: UInt64
    let bisectionInitialDivisor: UInt64
    let bisectionBinaryThreshold: UInt64
    let interpolationBinaryThreshold: UInt64
    let interpolationInitialDivisor: UInt64
    var convergenceStore: [Int: ConvergedOrigin] = [:]

    // MARK: - Leaf Position

    /// Metadata for a single integer leaf under value search.
    struct LeafPosition: ScopedLeafMutationSource {
        let nodeID: Int
        let sequenceIndex: Int
        let validRange: ClosedRange<UInt64>?
        var currentBitPattern: UInt64
        let targetBitPattern: UInt64
        let typeTag: TypeTag
        let mayReshape: Bool
        /// Simpler forms of the leaf's character, or nil when the leaf is not a character.
        let characterSimplifications: CharacterSimplifications?
    }

    // MARK: - Phase State

    /// Tracks the state of integer leaf reduction across its sub-phases, from batch zeroing through per-leaf interpolation search. Holds the working sequence, leaf metadata, the active stepper, and auxiliary state for cross-zero and linear scan recovery.
    struct State {
        var sequence: ChoiceSequence
        var leafPositions: [LeafPosition]
        var phase: Phase
        var leafIndex: Int
        var stepper: DirectionalStepper?
        var warmStartRecords: [Int: ConvergedOrigin]
        /// The last candidate emitted by nextProbe. When lastAccepted is true, this becomes the new baseline sequence.
        var lastEmittedCandidate: ChoiceSequence?
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
    }

    /// Where the candidates came from, which decides when the list ends and how its convergence is recorded.
    enum CandidateListSource: Equatable {
        /// Every bit pattern in a non-monotone gap of at most ``ScopedReductionTuning/valueLinearScanThreshold`` below the converged bound. Scanning continues past acceptances, and exhaustion records a `.scanComplete` convergence before trying cross-zero.
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
    }

    /// State for the cross-zero phase of per-leaf minimization.
    ///
    /// After bit-pattern binary search converges on one side of zero for a signed type, this phase enumerates shortlex keys from the simplest (key 0 ↔ value 0) upward. Each key decodes via ``ChoiceValue/fromShortlexKey(_:tag:)`` to a signed value on the opposite side of zero from the current convergence, closing the gap that bp-space binary search cannot bridge (for example, reducing value `1` to value `0` or `-1`).
    ///
    /// The first accepted probe is the simplest possible value for this leaf — walking upward from key 0 guarantees that any later acceptance would be strictly less simple, so the phase exits on first acceptance.
    struct CrossZeroState {
        let seqIdx: Int
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
    /// Performs joint interpolation search across groups of leaves. Each group probe moves all leaves in the group one interpolation step toward their targets simultaneously. On acceptance, the group's values update and the next step is tried. On rejection, the group is bisected into two halves that are searched independently. When a group is reduced to a single leaf, it is deferred to the per-leaf phase.
    struct BisectionState {
        /// Stack of leaf groups to search. Each group is a half-open interval into ``State/leafPositions``.
        var pendingGroups: [(start: Int, end: Int)]
        /// The group currently being searched. `nil` when no group is active (need to pop next from pending).
        var activeGroup: (start: Int, end: Int)?
        /// Current interpolation divisor for the active group. Halves on rejection, resets to ``ScopedReductionTuning/valueBisectionInitialDivisor`` on acceptance.
        var divisor: UInt64
        /// Whether we have emitted a probe for the active group and are awaiting feedback.
        var awaitingFeedback: Bool
        /// Leaf indices that were accepted during bisection and should be skipped in per-leaf phase.
        var convergedIndices: Set<Int>
    }

    /// Directional search stepper for bit-pattern-space search.
    ///
    /// Uses interpolation search for large ranges and plain binary search for small ranges. The threshold is ``ScopedReductionTuning/interpolationBinaryThreshold``.
    ///
    /// Exactly one of `binary` or `interpolation` is non-nil at any time. The flat-optional layout avoids the overhead of enum associated-value extraction and reconstruction on every call to ``advance(lastAccepted:)``, which sits on the reducer's tightest per-iteration loop.
    struct DirectionalStepper {
        private var binary: BinarySearchStepper?
        private var interpolation: InterpolationSearchStepper?

        var bestAccepted: UInt64 {
            binary?.bestAccepted ?? interpolation?.bestAccepted ?? 0
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
        tuning: ScopedReductionTuning
    ) {
        linearScanThreshold = tuning.valueLinearScanThreshold
        bisectionInitialDivisor = tuning.valueBisectionInitialDivisor
        bisectionBinaryThreshold = tuning.valueBisectionBinaryThreshold
        interpolationBinaryThreshold = tuning.interpolationBinaryThreshold
        interpolationInitialDivisor = tuning.interpolationInitialDivisor
        state = Self.initialState(scope: scope, sequence: sequence, graph: graph, warmStarts: warmStarts)
    }

    mutating func next(_ feedback: ScopedSearchFeedback, into buffer: inout ChoiceSequence) -> ScopedCandidate? {
        var current = state
        guard let built = nextProbe(state: &current, lastAccepted: feedback.isAccepted) else {
            state = current
            return nil
        }
        buffer = built
        let mutation = current.leafPositions.leafValuesMutation(candidate: buffer, baseline: current.sequence)
        state = current
        return .written(mutation: mutation, admission: .standard)
    }

    /// Reports the convergence records gathered so far, first recording a partial bound for the leaf in progress so its search resumes from there on the next dispatch.
    consuming func finish(reason _: ScopedStopReason, undelivered _: ScopedSearchFeedback?) -> ScopedSearchReport {
        flushPartialConvergence()
        return ScopedSearchReport(convergenceRecords: convergenceStore)
    }

    /// Writes a partial convergence record for the current in-progress leaf if the stepper has a best-accepted bound. Without this, the stepper's progress is lost and the search restarts from the warm-start bound on the next dispatch.
    private mutating func flushPartialConvergence() {
        guard state.leafIndex < state.leafPositions.count else {
            return
        }
        let leaf = state.leafPositions[state.leafIndex]
        guard convergenceStore[leaf.nodeID] == nil else {
            return
        }
        guard let bestAccepted = state.stepper?.bestAccepted else {
            return
        }
        convergenceStore[leaf.nodeID] = ConvergedOrigin(
            bound: bestAccepted,
            signal: .monotoneConvergence,
            configuration: .binarySearchSemanticSimplest,
            cycle: 0
        )
    }
}
