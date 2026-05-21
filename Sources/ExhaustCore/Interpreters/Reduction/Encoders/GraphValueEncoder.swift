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
/// - **bound value**: joint upstream/downstream minimization along a dependency edge. Internally a bound value composition — each upstream probe spawns a downstream search.
///
/// This is an active-path operation: all leaves have position ranges in the current sequence. Candidates are constructed by modifying leaf values at pre-resolved positions.
///
/// The integer- and float-mode implementations live in `GraphValueEncoder+Integer.swift` and `GraphValueEncoder+Float.swift` respectively. State types are nested here so both extensions can reference them, and the protocol-level dispatch (`start`, `nextProbe`, `refreshState`) sits in this core file.
struct GraphValueEncoder: GraphEncoder {
    let name: EncoderName = .valueSearch

    // MARK: - State

    var mode: Mode = .idle
    var convergenceStore: [Int: ConvergedOrigin] = [:]

    /// Controls which leaf reduction phase is active. The encoder is either idle (no scope loaded), reducing integer leaves, or reducing float leaves; each mode carries its own state type because the search strategies differ fundamentally.
    enum Mode {
        case idle
        case valueLeaves(IntegerState)
        case floatLeaves(FloatState)
    }

    var convergenceRecords: [Int: ConvergedOrigin] {
        convergenceStore
    }

    // MARK: - Leaf Mutation Source

    /// Common fields needed by ``buildLeafValuesMutation`` to diff a candidate against a baseline.
    protocol LeafMutationSource {
        var nodeID: Int { get }
        var sequenceIndex: Int { get }
        var mayReshape: Bool { get }
    }

    // MARK: - Integer Leaf Position

    /// Metadata for a single integer leaf under value search.
    struct IntegerLeafPosition: LeafMutationSource {
        let nodeID: Int
        let sequenceIndex: Int
        let validRange: ClosedRange<UInt64>?
        var currentBitPattern: UInt64
        let targetBitPattern: UInt64
        let typeTag: TypeTag
        let mayReshape: Bool
    }

    // MARK: - Integer State

    /// Tracks the state of integer leaf reduction across its sub-phases, from batch zeroing through per-leaf interpolation search. Holds the working sequence, leaf metadata, and the active phase with its per-phase state.
    struct IntegerState {
        var sequence: ChoiceSequence
        var leafPositions: [IntegerLeafPosition]
        var warmStartRecords: [Int: ConvergedOrigin]
        var lastEmittedCandidate: ChoiceSequence?
        var batchRejected: Bool
        var phase: IntegerPhase
    }

    /// Per-leaf phase state: binary search, linear scan recovery, and cross-zero for each leaf in sequence.
    struct PerLeafPhaseState {
        var leafIndex: Int
        var stepper: DirectionalStepper?
        var scanValues: [UInt64]?
        var scanIndex: Int
        var scanBestAccepted: UInt64?
        var crossZero: CrossZeroState?
        var semanticSimplestProbed: Bool
        var bisectionConvergedIndices: Set<Int>

        init(leafIndex: Int = 0, bisectionConvergedIndices: Set<Int> = []) {
            self.leafIndex = leafIndex
            self.stepper = nil
            self.scanValues = nil
            self.scanIndex = 0
            self.scanBestAccepted = nil
            self.crossZero = nil
            self.semanticSimplestProbed = false
            self.bisectionConvergedIndices = bisectionConvergedIndices
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

    /// Maximum remaining range size for which inline linear scan is emitted after binary search convergence.
    static let linearScanThreshold: UInt64 = 64

    /// Sub-phases of integer reduction, ordered from cheapest to most granular: batch zero tries all leaves at once, per-leaf zero probes each individually, batch bisect does group interpolation search, and per-leaf runs individual interpolation or binary search. Each case carries only the state relevant to that phase.
    enum IntegerPhase {
        case batchZero
        case perLeafZero(PerLeafZeroState)
        case batchBisect(BisectionState)
        case perLeaf(PerLeafPhaseState)
    }

    /// State for the per-leaf-zero pre-round.
    struct PerLeafZeroState {
        var leafCursor: Int = 0
        var convergedIndices: Set<Int> = []
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
    /// Uses interpolation search for large ranges and plain binary search for small ranges. The threshold is ``InterpolationSearchStepper/binaryThreshold``.
    enum DirectionalStepper {
        case binary(BinarySearchStepper)
        case interpolation(InterpolationSearchStepper)

        var bestAccepted: UInt64 {
            switch self {
            case let .binary(stepper): stepper.bestAccepted
            case let .interpolation(stepper): stepper.bestAccepted
            }
        }

        mutating func start() -> UInt64? {
            switch self {
            case var .binary(stepper):
                let value = stepper.start()
                self = .binary(stepper)
                return value
            case var .interpolation(stepper):
                let value = stepper.start()
                self = .interpolation(stepper)
                return value
            }
        }

        mutating func advance(lastAccepted: Bool) -> UInt64? {
            switch self {
            case var .binary(stepper):
                let value = stepper.advance(lastAccepted: lastAccepted)
                self = .binary(stepper)
                return value
            case var .interpolation(stepper):
                let value = stepper.advance(lastAccepted: lastAccepted)
                self = .interpolation(stepper)
                return value
            }
        }
    }

    // MARK: - Float State

    /// Tracks the reduction state for a single float leaf node, including its current value, bit pattern, type tag, and valid range constraints. Mutable fields update as probes are accepted so subsequent stages operate on the reduced value.
    struct FloatTarget: LeafMutationSource {
        let nodeID: Int
        let sequenceIndex: Int
        let typeTag: TypeTag
        let validRange: ClosedRange<UInt64>?
        let isRangeExplicit: Bool
        var currentValue: Double
        var currentBitPattern: UInt64
        let mayReshape: Bool
    }

    /// Represents the four stages of float reduction in ascending complexity: special values (zero, subnormal, normal), mantissa truncation, integral binary search, and ratio binary search. Ordered so that cheap constant-time probes run before iterative searches.
    enum FloatStage: Int, Comparable {
        case specialValues = 0
        case truncation = 1
        case integralBinarySearch = 2
        case ratioBinarySearch = 3

        static func < (lhs: FloatStage, rhs: FloatStage) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Tracks the overall state of float leaf reduction across all targets and stages, including the working sequence, the list of ``FloatTarget`` nodes, the current stage and target index, and binary search context shared between the integral and ratio stages.
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

    mutating func start(scope: EncoderInput) {
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
        case .laneCollapse:
            assertionFailure("laneCollapse scopes must route through GraphLaneCollapseEncoder, not GraphValueEncoder")
            mode = .idle
        case let .floatLeaves(floatScope):
            startFloat(scope: floatScope, sequence: sequence, graph: graph)
        case .boundValue:
            // bound value scopes are dispatched via ``GraphComposedEncoder``
            // constructed at the scheduler call site, never through this encoder.
            assertionFailure("boundValue scopes must route through GraphComposedEncoder, not GraphValueEncoder")
            mode = .idle
        }
    }

    /// Writes a partial convergence record for the current in-progress leaf if the stepper has a best-accepted bound.
    ///
    /// Called by the probe loop before harvesting convergence records when the loop breaks early (for example, due to a graph rebuild). Without this, the stepper's progress is lost and binary search restarts from the warm-start bound on the next dispatch.
    mutating func flushPartialConvergence() {
        guard case let .valueLeaves(state) = mode else { return }
        guard case let .perLeaf(perLeaf) = state.phase else { return }
        guard perLeaf.leafIndex < state.leafPositions.count else { return }
        let leaf = state.leafPositions[perLeaf.leafIndex]
        guard convergenceStore[leaf.nodeID] == nil else { return }
        guard let bestAccepted = perLeaf.stepper?.bestAccepted else { return }
        convergenceStore[leaf.nodeID] = ConvergedOrigin(
            bound: bestAccepted,
            signal: .monotoneConvergence,
            configuration: .binarySearchSemanticSimplest,
            cycle: 0
        )
    }

    mutating func nextProbe(into candidate: inout ChoiceSequence, lastAccepted: Bool) -> EncoderProbe? {
        switch mode {
        case .idle:
            return nil
        case var .valueLeaves(state):
            guard let built = nextIntegerProbe(state: &state, lastAccepted: lastAccepted) else {
                mode = .valueLeaves(state)
                return nil
            }
            candidate = built
            let mutation = buildIntegerLeafValuesMutation(candidate: candidate, state: state)
            mode = .valueLeaves(state)
            return mutation
        case var .floatLeaves(state):
            guard let built = nextFloatProbe(state: &state, lastAccepted: lastAccepted) else {
                mode = .floatLeaves(state)
                return nil
            }
            candidate = built
            let mutation = buildFloatLeafValuesMutation(candidate: candidate, state: state)
            mode = .floatLeaves(state)
            return mutation
        }
    }

    // MARK: - Mutation Builders

    /// Builds a `.leafValues` mutation report by comparing the candidate against the integer state's current baseline.
    func buildIntegerLeafValuesMutation(
        candidate: ChoiceSequence,
        state: IntegerState
    ) -> ProjectedMutation {
        buildLeafValuesMutation(candidate: candidate, baseline: state.sequence, leaves: state.leafPositions)
    }

    /// Builds a `.leafValues` mutation report by comparing the candidate against the float state's current baseline.
    func buildFloatLeafValuesMutation(
        candidate: ChoiceSequence,
        state: FloatState
    ) -> ProjectedMutation {
        buildLeafValuesMutation(candidate: candidate, baseline: state.sequence, leaves: state.targets)
    }

    /// Builds a `.leafValues` mutation by diffing candidate against baseline at each leaf's sequence index.
    private func buildLeafValuesMutation(
        candidate: ChoiceSequence,
        baseline: ChoiceSequence,
        leaves: some Sequence<LeafMutationSource>
    ) -> ProjectedMutation {
        var changes: [LeafChange] = []
        for leaf in leaves {
            guard leaf.sequenceIndex < candidate.count,
                  leaf.sequenceIndex < baseline.count
            else { continue }
            guard let candidateChoice = candidate[leaf.sequenceIndex].value?.choice,
                  let baselineChoice = baseline[leaf.sequenceIndex].value?.choice
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
}

// MARK: - ChoiceSequence Value Helpers

extension ChoiceSequenceValue {
    /// Returns a copy of this entry with the value's bit pattern replaced, preserving range metadata and type tag.
    ///
    /// - Precondition: The entry must be a `.value` case. Calling on structural markers (`.group`, `.sequence`, `.bind`, `.branch`, `.just`) triggers a precondition failure.
    func withBitPattern(_ bitPattern: UInt64) -> ChoiceSequenceValue {
        switch self {
        case let .value(value):
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
