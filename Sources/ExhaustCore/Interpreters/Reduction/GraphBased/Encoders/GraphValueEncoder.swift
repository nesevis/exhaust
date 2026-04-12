//
//  GraphValueEncoder.swift
//  Exhaust
//

// MARK: - Graph Minimization Encoder

/// Drives leaf values toward their semantic simplest without changing graph structure.
///
/// Operates in three modes based on the ``MinimizationScope``:
/// - **Integer leaves**: batch zeroing attempt followed by per-leaf interpolation search via ``InterpolationSearchStepper`` (falling back to binary search below a threshold), with cross-zero phase for signed integers.
/// - **Float leaves**: four-stage IEEE 754 pipeline (special values, truncation, integral binary search, ratio binary search).
/// - **Kleisli fibre**: joint upstream/downstream minimization along a dependency edge. Internally a Kleisli composition — each upstream probe spawns a downstream search.
///
/// This is an active-path operation: all leaves have position ranges in the current sequence. Candidates are constructed by modifying leaf values at pre-resolved positions.
///
/// The integer- and float-mode implementations live in `GraphValueEncoder+Integer.swift` and `GraphValueEncoder+Float.swift` respectively. State types are nested here so both extensions can reference them, and the protocol-level dispatch (`start`, `nextProbe`, `refreshScope`) sits in this core file.
struct GraphValueEncoder: GraphEncoder {
    let name: EncoderName = .graphValueSearch

    // MARK: - State

    var mode: Mode = .idle
    var convergenceStore: [Int: ConvergedOrigin] = [:]

    enum Mode {
        case idle
        case valueLeaves(IntegerState)
        case floatLeaves(FloatState)
    }

    var convergenceRecords: [Int: ConvergedOrigin] {
        convergenceStore
    }

    // MARK: - Integer State

    struct IntegerState {
        var sequence: ChoiceSequence
        var leafPositions: [(nodeID: Int, sequenceIndex: Int, validRange: ClosedRange<UInt64>?, currentBitPattern: UInt64, targetBitPattern: UInt64, typeTag: TypeTag, mayReshape: Bool)]
        var phase: IntegerPhase
        var leafIndex: Int
        var stepper: DirectionalStepper?
        var warmStartRecords: [Int: ConvergedOrigin]
        /// The last candidate emitted by nextProbe. When lastAccepted is true, this becomes the new baseline sequence.
        var lastEmittedCandidate: ChoiceSequence?
        /// Whether the batch-zero probe was rejected. When true and a leaf individually converges at its target, the convergence signal is `zeroingDependency` instead of `monotoneConvergence`.
        var batchRejected: Bool
        /// Linear scan values for non-monotone gap recovery, or nil when inactive.
        var scanValues: [UInt64]?
        var scanIndex: Int
        /// Best accepted value during the linear scan phase.
        var scanBestAccepted: UInt64?
        /// Cross-zero phase state for the current leaf, or nil when inactive. Set after binary search (and any linear scan recovery) converges on a signed-type leaf whose current shortlex key permits crossing zero.
        var crossZero: CrossZeroState?
        /// Batch bisection state, active during the ``IntegerPhase/batchBisect`` phase.
        var bisection: BisectionState?
        /// Whether the reduction target has been probed directly for the current leaf. Reset when advancing to the next leaf.
        var semanticSimplestProbed: Bool = false
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

    /// Maximum remaining range size for which inline linear scan is emitted after binary search convergence.
    static let linearScanThreshold: UInt64 = 64

    enum IntegerPhase {
        case batchZero
        case batchBisect
        case perLeaf
    }

    /// State for the batch bisection phase.
    ///
    /// Performs joint interpolation search across groups of leaves. Each group probe moves all leaves in the group one interpolation step toward their targets simultaneously. On acceptance, the group's values update and the next step is tried. On rejection, the group is bisected into two halves that are searched independently. When a group shrinks to a single leaf, it is deferred to the per-leaf phase.
    struct BisectionState {
        /// Stack of leaf groups to search. Each group is a half-open interval into ``IntegerState/leafPositions``.
        var pendingGroups: [(start: Int, end: Int)]
        /// The group currently being searched. `nil` when no group is active (need to pop next from pending).
        var activeGroup: (start: Int, end: Int)?
        /// Current interpolation divisor for the active group. Halves on rejection, resets on acceptance.
        var divisor: UInt64
        /// Whether we have emitted a probe for the active group and are awaiting feedback.
        var awaitingFeedback: Bool
        /// Leaf indices that were accepted during bisection and should be skipped in per-leaf phase.
        var convergedIndices: Set<Int>

        static let initialDivisor: UInt64 = 16
        static let binaryThreshold: UInt64 = 4
    }

    /// Directional search stepper for bit-pattern-space search.
    ///
    /// Uses interpolation search for large ranges (`downward` / `upward`) and plain binary search for small ranges (`downwardBinary` / `upwardBinary`). The threshold is ``InterpolationSearchStepper/binaryThreshold``.
    enum DirectionalStepper {
        case downward(InterpolationSearchStepper)
        case downwardBinary(BinarySearchStepper)
        case upward(MaxInterpolationSearchStepper)
        case upwardBinary(MaxBinarySearchStepper)

        var bestAccepted: UInt64 {
            switch self {
            case let .downward(stepper): stepper.bestAccepted
            case let .downwardBinary(stepper): stepper.bestAccepted
            case let .upward(stepper): stepper.bestAccepted
            case let .upwardBinary(stepper): stepper.bestAccepted
            }
        }

        mutating func start() -> UInt64? {
            switch self {
            case var .downward(stepper):
                let value = stepper.start()
                self = .downward(stepper)
                return value
            case var .downwardBinary(stepper):
                let value = stepper.start()
                self = .downwardBinary(stepper)
                return value
            case var .upward(stepper):
                let value = stepper.start()
                self = .upward(stepper)
                return value
            case var .upwardBinary(stepper):
                let value = stepper.start()
                self = .upwardBinary(stepper)
                return value
            }
        }

        mutating func advance(lastAccepted: Bool) -> UInt64? {
            switch self {
            case var .downward(stepper):
                let value = stepper.advance(lastAccepted: lastAccepted)
                self = .downward(stepper)
                return value
            case var .downwardBinary(stepper):
                let value = stepper.advance(lastAccepted: lastAccepted)
                self = .downwardBinary(stepper)
                return value
            case var .upward(stepper):
                let value = stepper.advance(lastAccepted: lastAccepted)
                self = .upward(stepper)
                return value
            case var .upwardBinary(stepper):
                let value = stepper.advance(lastAccepted: lastAccepted)
                self = .upwardBinary(stepper)
                return value
            }
        }
    }

    // MARK: - Float State

    struct FloatTarget {
        let nodeID: Int
        let sequenceIndex: Int
        let typeTag: TypeTag
        let validRange: ClosedRange<UInt64>?
        let isRangeExplicit: Bool
        var currentValue: Double
        var currentBitPattern: UInt64
        let mayReshape: Bool
    }

    enum FloatStage: Int, Comparable {
        case specialValues = 0
        case truncation = 1
        case integralBinarySearch = 2
        case ratioBinarySearch = 3

        static func < (lhs: FloatStage, rhs: FloatStage) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct FloatState {
        var sequence: ChoiceSequence
        var targets: [FloatTarget]
        var currentTargetIndex: Int
        var stage: FloatStage
        var batchCandidates: [UInt64]
        var batchIndex: Int
        var stepper: FindIntegerStepper
        var needsFirstProbe: Bool
        var lastEmittedCandidate: ChoiceSequence?
        // Stage 2/3 binary search context.
        var binarySearchMinDelta: UInt64
        var binarySearchMaxQuantum: UInt64
        var binarySearchMovesUp: Bool
        var binarySearchCurrentInt: Int64
        // Stage 3 ratio context.
        var ratioDenominator: Int64
        var ratioRemainder: Int64
        var ratioIntegerPart: Int64
        var ratioDistance: UInt64
    }

    // MARK: - GraphEncoder

    mutating func start(scope: TransformationScope) {
        convergenceStore = [:]

        guard case let .minimize(minimizationScope) = scope.transformation.operation else {
            mode = .idle
            return
        }

        let sequence = scope.baseSequence
        let graph = scope.graph

        switch minimizationScope {
        case let .valueLeaves(integerScope):
            startInteger(scope: integerScope, sequence: sequence, graph: graph, warmStarts: scope.warmStartRecords)
        case let .floatLeaves(floatScope):
            startFloat(scope: floatScope, sequence: sequence, graph: graph)
        case .kleisliFibre:
            // Kleisli fibre scopes are dispatched via ``GraphComposedEncoder``
            // constructed at the scheduler call site, never through this encoder.
            // Reaching this branch indicates a routing bug.
            assertionFailure("kleisliFibre scopes must route through GraphComposedEncoder, not GraphValueEncoder")
            mode = .idle
        }
    }

    mutating func refreshScope(graph: ChoiceGraph, sequence: ChoiceSequence) {
        // Re-derive the encoder's working set from the live graph after a
        // structural mutation. The scheduler calls this between probe loop
        // iterations whenever the most recent acceptance added or removed
        // graph nodes (an in-place reshape via ``applyBindReshape``).
        // The cached ``IntegerState/leafPositions`` /
        // ``FloatState/targets`` reference pre-mutation node IDs and
        // sequence positions; without a refresh the next probe would write
        // to a stale slot or invoke ``applyLeafValueWrite`` on a tombstoned
        // node, producing the position drift bug documented in
        // ExhaustDocs/graph-reducer-position-drift-bug.md.
        //
        // Strategy: pull the canonical integer/float scope from
        // ``graph.minimizationScopes()`` against the live graph (which
        // automatically picks up new leaves the splice created and drops
        // tombstoned ones), filter out leaves we have already converged in
        // this pass via ``convergenceStore``, and replace the per-mode
        // state in place. Convergence records keyed by nodeID survive any
        // number of refreshes; records for tombstoned IDs are dropped so
        // they cannot leak across the boundary.
        //
        // The leafIndex, in-flight stepper, scan window, and cross-zero
        // phase are all per-leaf state from the pre-refresh leaf set and
        // are reset. The phase is re-armed to ``IntegerPhase/batchZero``
        // (when more than one leaf is in the new set) so the new leaves
        // get a chance at the joint-zero probe; the cost is one extra
        // probe per refresh.
        // Drop convergence records whose nodeID has been tombstoned by the
        // splice — those nodes no longer exist and recording their
        // convergence onto the live graph at end-of-pass would be a no-op.
        // Done before reading the new scope so the predicate sees a clean
        // store.
        for nodeID in convergenceStore.keys
            where nodeID >= graph.nodes.count || graph.nodes[nodeID].positionRange == nil
        {
            convergenceStore.removeValue(forKey: nodeID)
        }

        switch mode {
        case .idle:
            return
        case let .valueLeaves(state):
            let scopes = MinimizationScopeQuery.build(graph: graph)
            let integerScope = scopes.firstNonNil { scope -> ValueMinimizationScope? in
                if case let .valueLeaves(inner) = scope { return inner }
                return nil
            }
            guard let integerScope else {
                mode = .idle
                return
            }
            startInteger(
                scope: integerScope,
                sequence: sequence,
                graph: graph,
                warmStarts: state.warmStartRecords,
                preservingConvergence: convergenceStore,
                armBatchZero: false
            )
        case .floatLeaves:
            let scopes = MinimizationScopeQuery.build(graph: graph)
            let floatScope = scopes.firstNonNil { scope -> FloatMinimizationScope? in
                if case let .floatLeaves(inner) = scope { return inner }
                return nil
            }
            guard let floatScope else {
                mode = .idle
                return
            }
            startFloat(
                scope: floatScope,
                sequence: sequence,
                graph: graph,
                preservingConvergence: convergenceStore
            )
        }
    }

    mutating func nextProbe(lastAccepted: Bool) -> EncoderProbe? {
        switch mode {
        case .idle:
            return nil
        case var .valueLeaves(state):
            guard let candidate = nextIntegerProbe(state: &state, lastAccepted: lastAccepted) else {
                mode = .valueLeaves(state)
                return nil
            }
            let mutation = buildIntegerLeafValuesMutation(candidate: candidate, state: state)
            mode = .valueLeaves(state)
            return EncoderProbe(candidate: candidate, mutation: mutation)
        case var .floatLeaves(state):
            guard let candidate = nextFloatProbe(state: &state, lastAccepted: lastAccepted) else {
                mode = .floatLeaves(state)
                return nil
            }
            let mutation = buildFloatLeafValuesMutation(candidate: candidate, state: state)
            mode = .floatLeaves(state)
            return EncoderProbe(candidate: candidate, mutation: mutation)
        }
    }

    // MARK: - Mutation Builders

    /// Builds a `.leafValues` mutation report by comparing the candidate against the integer state's current baseline. Each leaf in ``IntegerState/leafPositions`` is checked at its sequence index; differing values become ``LeafChange`` entries that carry the leaf's bind-inner reshape marker through to ``ChoiceGraph/apply(_:freshTree:)``.
    func buildIntegerLeafValuesMutation(
        candidate: ChoiceSequence,
        state: IntegerState
    ) -> ProjectedMutation {
        var changes: [LeafChange] = []
        for leaf in state.leafPositions {
            guard leaf.sequenceIndex < candidate.count,
                  leaf.sequenceIndex < state.sequence.count
            else { continue }
            guard let candidateChoice = candidate[leaf.sequenceIndex].value?.choice,
                  let baselineChoice = state.sequence[leaf.sequenceIndex].value?.choice
            else { continue }
            guard candidateChoice != baselineChoice else { continue }
            changes.append(LeafChange(
                leafNodeID: leaf.nodeID,
                newValue: candidateChoice,
                mayReshape: leaf.mayReshape
            ))
        }
        return .leafValues(changes)
    }

    /// Builds a `.leafValues` mutation report by comparing the candidate against the float state's current baseline.
    func buildFloatLeafValuesMutation(
        candidate: ChoiceSequence,
        state: FloatState
    ) -> ProjectedMutation {
        var changes: [LeafChange] = []
        for target in state.targets {
            guard target.sequenceIndex < candidate.count,
                  target.sequenceIndex < state.sequence.count
            else { continue }
            guard let candidateChoice = candidate[target.sequenceIndex].value?.choice,
                  let baselineChoice = state.sequence[target.sequenceIndex].value?.choice
            else { continue }
            guard candidateChoice != baselineChoice else { continue }
            changes.append(LeafChange(
                leafNodeID: target.nodeID,
                newValue: candidateChoice,
                mayReshape: target.mayReshape
            ))
        }
        return .leafValues(changes)
    }
}

// MARK: - ChoiceSequence Value Helpers

extension ChoiceSequenceValue {
    /// Returns a copy of this entry with the value's bit pattern replaced, preserving range metadata and type tag.
    ///
    /// - Precondition: The entry must be a `.value` or `.reduced` case. Calling on structural markers (`.group`, `.sequence`, `.bind`, `.branch`, `.just`) triggers a precondition failure.
    func withBitPattern(_ bitPattern: UInt64) -> ChoiceSequenceValue {
        switch self {
        case let .value(value), let .reduced(value):
            let newChoice = ChoiceValue(
                bitPattern,
                tag: value.choice.tag
            )
            return .value(.init(
                choice: newChoice,
                validRange: value.validRange,
                isRangeExplicit: value.isRangeExplicit
            ))
        default:
            preconditionFailure("withBitPattern called on non-value entry: \(self)")
        }
    }
}
