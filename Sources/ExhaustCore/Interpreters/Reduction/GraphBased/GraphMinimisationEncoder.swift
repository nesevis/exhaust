//
//  GraphMinimizationEncoder.swift
//  Exhaust
//

// MARK: - Graph Minimization Encoder

/// Drives leaf values toward their semantic simplest without changing graph structure.
///
/// Operates in three modes based on the ``MinimizationScope``:
/// - **Integer leaves**: batch zeroing attempt followed by per-leaf binary search via ``BinarySearchStepper``, with cross-zero phase for signed integers.
/// - **Float leaves**: four-stage IEEE 754 pipeline (special values, truncation, integral binary search, ratio binary search).
/// - **Kleisli fibre**: joint upstream/downstream minimization along a dependency edge. Internally a Kleisli composition — each upstream probe spawns a downstream search.
///
/// This is an active-path operation: all leaves have position ranges in the current sequence. Candidates are constructed by modifying leaf values at pre-resolved positions.
struct GraphMinimizationEncoder: GraphEncoder {
    let name: EncoderName = .graphValueSearch

    // MARK: - State

    private var mode: Mode = .idle
    private var convergenceStore: [Int: ConvergedOrigin] = [:]

    private enum Mode {
        case idle
        case integerLeaves(IntegerState)
        case floatLeaves(FloatState)
        case kleisliFibre
    }

    var convergenceRecords: [Int: ConvergedOrigin] {
        convergenceStore
    }

    // MARK: - Integer State

    private struct IntegerState {
        var sequence: ChoiceSequence
        let leafPositions: [(nodeID: Int, sequenceIndex: Int, validRange: ClosedRange<UInt64>?, currentBitPattern: UInt64, targetBitPattern: UInt64, typeTag: TypeTag, mayReshape: Bool)]
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
    }

    /// State for the cross-zero phase of per-leaf minimization.
    ///
    /// After bit-pattern binary search converges on one side of zero for a signed type, this phase enumerates shortlex keys from the simplest (key 0 ↔ value 0) upward. Each key decodes via ``ChoiceValue/fromShortlexKey(_:tag:)`` to a signed value on the opposite side of zero from the current convergence, closing the gap that bp-space binary search cannot bridge (e.g. reducing value `1` to value `0` or `-1`).
    ///
    /// The first accepted probe is the simplest possible value for this leaf — walking upward from key 0 guarantees that any later acceptance would be strictly less simple, so the phase exits on first acceptance.
    private struct CrossZeroState {
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
    private static let linearScanThreshold: UInt64 = 64

    private enum IntegerPhase {
        case batchZero
        case perLeaf
    }

    /// Directional binary search stepper for bit-pattern-space search.
    ///
    /// Downward (currentBP > targetBP): finds the smallest accepted bit pattern. Upward (currentBP < targetBP): finds the largest accepted bit pattern. Matches the directional strategy in Bonsai's ``BinarySearchEncoder``.
    private enum DirectionalStepper {
        case downward(BinarySearchStepper)
        case upward(MaxBinarySearchStepper)

        var bestAccepted: UInt64 {
            switch self {
            case let .downward(stepper): stepper.bestAccepted
            case let .upward(stepper): stepper.bestAccepted
            }
        }

        mutating func start() -> UInt64? {
            switch self {
            case var .downward(stepper):
                let value = stepper.start()
                self = .downward(stepper)
                return value
            case var .upward(stepper):
                let value = stepper.start()
                self = .upward(stepper)
                return value
            }
        }

        mutating func advance(lastAccepted: Bool) -> UInt64? {
            switch self {
            case var .downward(stepper):
                let value = stepper.advance(lastAccepted: lastAccepted)
                self = .downward(stepper)
                return value
            case var .upward(stepper):
                let value = stepper.advance(lastAccepted: lastAccepted)
                self = .upward(stepper)
                return value
            }
        }
    }


    // MARK: - Float State

    private struct FloatTarget {
        let nodeID: Int
        let sequenceIndex: Int
        let typeTag: TypeTag
        let validRange: ClosedRange<UInt64>?
        let isRangeExplicit: Bool
        var currentValue: Double
        var currentBitPattern: UInt64
        let mayReshape: Bool
    }

    private enum FloatStage: Int, Comparable {
        case specialValues = 0
        case truncation = 1
        case integralBinarySearch = 2
        case ratioBinarySearch = 3

        static func < (lhs: FloatStage, rhs: FloatStage) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private struct FloatState {
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
        case let .integerLeaves(integerScope):
            startInteger(scope: integerScope, sequence: sequence, graph: graph, warmStarts: scope.warmStartRecords)
        case let .floatLeaves(floatScope):
            startFloat(scope: floatScope, sequence: sequence, graph: graph)
        case .kleisliFibre:
            // Kleisli fibre: complex interleaved search — stub for now.
            mode = .kleisliFibre
        }
    }

    mutating func nextProbe(lastAccepted: Bool) -> EncoderProbe? {
        switch mode {
        case .idle, .kleisliFibre:
            return nil
        case var .integerLeaves(state):
            guard let candidate = nextIntegerProbe(state: &state, lastAccepted: lastAccepted) else {
                mode = .integerLeaves(state)
                return nil
            }
            let mutation = buildIntegerLeafValuesMutation(candidate: candidate, state: state)
            mode = .integerLeaves(state)
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

    /// Builds a `.leafValues` mutation report by comparing the candidate against the integer state's current baseline. Each leaf in ``IntegerState/leafPositions`` is checked at its sequence index; differing values become ``LeafChange`` entries that carry the leaf's bind-inner reshape marker through to ``ChoiceGraph/apply(_:freshTree:)``.
    private func buildIntegerLeafValuesMutation(
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
    private func buildFloatLeafValuesMutation(
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

    // MARK: - Integer Mode

    private mutating func startInteger(
        scope: IntegerMinimizationScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph,
        warmStarts: [Int: ConvergedOrigin]
    ) {
        var leafPositions: [(nodeID: Int, sequenceIndex: Int, validRange: ClosedRange<UInt64>?, currentBitPattern: UInt64, targetBitPattern: UInt64, typeTag: TypeTag, mayReshape: Bool)] = []

        for entry in scope.leaves {
            let nodeID = entry.nodeID
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            guard let range = graph.nodes[nodeID].positionRange else { continue }
            // Verify the sequence position is a value entry. After
            // structural changes within a cycle, position mappings from
            // an incrementally-refreshed graph may point at structural
            // markers instead of values.
            guard range.lowerBound < sequence.count,
                  sequence[range.lowerBound].value != nil else { continue }
            let current = metadata.value.bitPattern64
            let target = metadata.value.reductionTarget(in: metadata.validRange)
            if current != target {
                leafPositions.append((
                    nodeID: nodeID,
                    sequenceIndex: range.lowerBound,
                    validRange: metadata.validRange,
                    currentBitPattern: current,
                    targetBitPattern: target,
                    typeTag: metadata.typeTag,
                    mayReshape: entry.mayReshapeOnAcceptance
                ))
            }
        }

        mode = .integerLeaves(IntegerState(
            sequence: sequence,
            leafPositions: leafPositions,
            phase: scope.batchZeroEligible ? .batchZero : .perLeaf,
            leafIndex: 0,
            stepper: nil,
            warmStartRecords: warmStarts,
            lastEmittedCandidate: nil,
            batchRejected: false,
            scanValues: nil,
            scanIndex: 0,
            scanBestAccepted: nil,
            crossZero: nil
        ))
    }

    private mutating func nextIntegerProbe(
        state: inout IntegerState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        // If the last probe was accepted, update the baseline sequence.
        if lastAccepted, let accepted = state.lastEmittedCandidate {
            state.sequence = accepted
        }
        state.lastEmittedCandidate = nil

        switch state.phase {
        case .batchZero:
            state.phase = .perLeaf
            // Try setting all leaves to their targets simultaneously.
            var candidate = state.sequence
            for leaf in state.leafPositions {
                candidate[leaf.sequenceIndex] = candidate[leaf.sequenceIndex]
                    .withBitPattern(leaf.targetBitPattern)
            }
            if candidate.shortLexPrecedes(state.sequence) {
                state.lastEmittedCandidate = candidate
                return candidate
            }
            // Batch zero rejected — per-leaf convergence at target indicates dependency.
            state.batchRejected = true
            return nextIntegerProbe(state: &state, lastAccepted: false)

        case .perLeaf:
            return nextPerLeafProbe(state: &state, lastAccepted: lastAccepted)
        }
    }

    private mutating func nextPerLeafProbe(
        state: inout IntegerState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        while state.leafIndex < state.leafPositions.count {
            // Cross-zero phase takes priority when active — it was armed by a
            // prior iteration of this loop after binary search converged, and
            // the current `lastAccepted` is feedback for the last cross-zero
            // probe (if any).
            if state.crossZero != nil {
                if let candidate = nextCrossZeroProbe(
                    state: &state,
                    lastAccepted: lastAccepted
                ) {
                    return candidate
                }
                // Cross-zero exhausted or accepted — move to the next leaf.
                state.crossZero = nil
                state.leafIndex += 1
                continue
            }

            // Linear scan phase (set up by binary search on non-monotone gap).
            if state.scanValues != nil {
                if let candidate = nextLinearScanProbe(
                    state: &state,
                    lastAccepted: lastAccepted
                ) {
                    return candidate
                }
                // Scan exhausted — record convergence, then try cross-zero
                // before advancing to the next leaf. Linear scan probes only
                // `[targetBP, bestAccepted)` which for signed types is one
                // side of zero; cross-zero walks shortlex keys from 0 upward
                // and reaches values on the opposite side that linear scan
                // cannot. They are complementary.
                finishLinearScan(state: &state)
                if tryEnterCrossZero(state: &state) {
                    continue
                }
                state.leafIndex += 1
                continue
            }

            // Binary search phase.
            if let candidate = nextBitPatternSearchProbe(
                state: &state,
                lastAccepted: lastAccepted
            ) {
                return candidate
            }

            // Binary search converged. If scan was set up, loop back
            // to drain it.
            if state.scanValues != nil {
                continue
            }

            // Try to enter the cross-zero phase for signed types. If
            // successful, the next iteration of this loop will emit the
            // first cross-zero probe with fresh state (no stale feedback).
            if tryEnterCrossZero(state: &state) {
                continue
            }

            state.leafIndex += 1
        }

        return nil
    }

    // MARK: - Bit-Pattern Binary Search

    /// Drives the per-leaf binary search in bit-pattern space.
    ///
    /// Returns the next candidate, or nil when the stepper converges. On convergence, records the convergence signal and enters the cross-zero phase for signed types.
    private mutating func nextBitPatternSearchProbe(
        state: inout IntegerState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        let leaf = state.leafPositions[state.leafIndex]

        if state.stepper == nil {
            // Initialize directional stepper in bit-pattern space.
            let currentEntry = state.sequence[leaf.sequenceIndex]
            guard let currentChoice = currentEntry.value?.choice else {
                return nil
            }
            let currentBP = currentChoice.bitPattern64
            let targetBP = leaf.targetBitPattern

            guard currentBP != targetBP else {
                return nil
            }

            // Warm-start: if a prior cycle converged this leaf with the
            // same encoder configuration, narrow the search bounds to
            // skip the already-explored region.
            let warmStart = state.warmStartRecords[leaf.sequenceIndex]
            let validWarmStart = warmStart?.configuration == .binarySearchSemanticSimplest
                ? warmStart : nil

            if currentBP > targetBP {
                let effectiveLo = validWarmStart?.bound ?? targetBP
                state.stepper = .downward(
                    BinarySearchStepper(lo: effectiveLo, hi: currentBP)
                )
            } else {
                let effectiveHi = validWarmStart?.bound ?? targetBP
                state.stepper = .upward(
                    MaxBinarySearchStepper(lo: currentBP, hi: effectiveHi)
                )
            }

            guard let firstBP = state.stepper?.start() else {
                state.stepper = nil
                return nil
            }

            var candidate = state.sequence
            candidate[leaf.sequenceIndex] = candidate[leaf.sequenceIndex]
                .withBitPattern(firstBP)
            if candidate.shortLexPrecedes(state.sequence) {
                state.lastEmittedCandidate = candidate
                return candidate
            }
        }

        if let nextBP = state.stepper?.advance(lastAccepted: lastAccepted) {
            var candidate = state.sequence
            candidate[leaf.sequenceIndex] = candidate[leaf.sequenceIndex]
                .withBitPattern(nextBP)
            if candidate.shortLexPrecedes(state.sequence) {
                state.lastEmittedCandidate = candidate
                return candidate
            }
            // Probe not shortlex-smaller — re-enter to advance again.
            return nextBitPatternSearchProbe(
                state: &state,
                lastAccepted: false
            )
        }

        // Stepper converged — check for non-monotone gap.
        if let bestAccepted = state.stepper?.bestAccepted {
            let remaining: UInt64 = bestAccepted > leaf.targetBitPattern
                ? bestAccepted - leaf.targetBitPattern
                : leaf.targetBitPattern - bestAccepted

            if state.batchRejected && bestAccepted == leaf.targetBitPattern {
                // Leaf converged at target but batch-zero failed — zeroing dependency.
                convergenceStore[leaf.sequenceIndex] = ConvergedOrigin(
                    bound: bestAccepted,
                    signal: .zeroingDependency,
                    configuration: .binarySearchSemanticSimplest,
                    cycle: 0
                )
            } else if remaining > 0, remaining <= Self.linearScanThreshold {
                // Non-monotone gap: binary search couldn't reach the target
                // but the gap is small enough to scan exhaustively.
                convergenceStore[leaf.sequenceIndex] = ConvergedOrigin(
                    bound: bestAccepted,
                    signal: .nonMonotoneGap(remainingRange: Int(remaining)),
                    configuration: .binarySearchSemanticSimplest,
                    cycle: 0
                )
                // Set up inline linear scan of [targetBP, bestAccepted).
                let scanLo = min(leaf.targetBitPattern, bestAccepted)
                let scanHi = max(leaf.targetBitPattern, bestAccepted)
                var values: [UInt64] = []
                values.reserveCapacity(Int(remaining))
                var current = scanLo
                while current < scanHi {
                    values.append(current)
                    current += 1
                }
                state.scanValues = values
                state.scanIndex = 0
                state.scanBestAccepted = nil
            } else {
                convergenceStore[leaf.sequenceIndex] = ConvergedOrigin(
                    bound: bestAccepted,
                    signal: .monotoneConvergence,
                    configuration: .binarySearchSemanticSimplest,
                    cycle: 0
                )
            }
        }
        state.stepper = nil
        return nil
    }

    // MARK: - Linear Scan Recovery

    /// Scans values in the non-monotone gap to find a lower floor than binary search achieved.
    private mutating func nextLinearScanProbe(
        state: inout IntegerState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        let leaf = state.leafPositions[state.leafIndex]

        // Track acceptance of previous scan probe.
        if lastAccepted, state.scanIndex > 0 {
            let acceptedValue = state.scanValues![state.scanIndex - 1]
            if state.scanBestAccepted == nil || acceptedValue < state.scanBestAccepted! {
                state.scanBestAccepted = acceptedValue
            }
        }

        guard let scanValues = state.scanValues else { return nil }
        guard state.scanIndex < scanValues.count else { return nil }

        let probeValue = scanValues[state.scanIndex]
        state.scanIndex += 1

        var candidate = state.sequence
        candidate[leaf.sequenceIndex] = candidate[leaf.sequenceIndex]
            .withBitPattern(probeValue)

        guard candidate.shortLexPrecedes(state.sequence) else {
            // Value doesn't improve shortlex — skip to next.
            return nextLinearScanProbe(state: &state, lastAccepted: false)
        }

        state.lastEmittedCandidate = candidate
        return candidate
    }

    /// Records the final convergence from a completed linear scan.
    private mutating func finishLinearScan(state: inout IntegerState) {
        let leaf = state.leafPositions[state.leafIndex]
        let foundLowerFloor = state.scanBestAccepted != nil
        let bound = state.scanBestAccepted
            ?? convergenceStore[leaf.sequenceIndex]?.bound
            ?? leaf.targetBitPattern
        convergenceStore[leaf.sequenceIndex] = ConvergedOrigin(
            bound: bound,
            signal: .scanComplete(foundLowerFloor: foundLowerFloor),
            configuration: .linearScan,
            cycle: 0
        )
        state.scanValues = nil
        state.scanIndex = 0
        state.scanBestAccepted = nil
    }

    // MARK: - Cross-Zero Phase

    /// Attempts to arm the cross-zero phase for the current leaf.
    ///
    /// Returns `true` when the leaf is a signed type with a current shortlex key > 0 (there is at least one strictly simpler value to try). On success, ``IntegerState/crossZero`` is set and the per-leaf dispatch loop will emit the first probe on its next iteration.
    ///
    /// The probe budget adapts to the current shortlex key: roughly `log₂(key) + 4`, clamped to `[4, 16]`. Rationale: bit-pattern binary search has already covered the large-magnitude neighborhood by the time cross-zero runs, so cross-zero's contribution is bounded to the last few shortlex keys near zero. Small-magnitude leaves get full coverage of every key below their current one; large-magnitude leaves get the simplest 16 keys. Bonsai's fixed 16-probe cap is a special case of this at the upper end of the range.
    private mutating func tryEnterCrossZero(state: inout IntegerState) -> Bool {
        let leaf = state.leafPositions[state.leafIndex]
        guard leaf.typeTag.isSigned else { return false }
        guard let currentEntry = state.sequence[leaf.sequenceIndex].value else {
            return false
        }
        let currentKey = currentEntry.choice.shortlexKey
        guard currentKey > 0 else { return false }

        // Micro-opt 1: skip cross-zero when `value(0)` is outside an explicit
        // valid range. Every cross-zero probe walks shortlex keys near zero,
        // and if zero itself is out of range the walk's near neighbors are
        // almost certainly out too — the materializer will reject every probe
        // we emit. For generators like `int(in: 1...1000)` this saves the full
        // budget of wasted probes per leaf.
        //
        // The zero bit pattern is computed via `semanticSimplest.bitPattern64`
        // rather than `makeConvertible(bitPattern64: 0)`: for signed types the
        // XOR sign-magnitude encoding maps bit pattern 0 to the most negative
        // value, so `makeConvertible(bitPattern64: 0)` would return `Int.min`,
        // not semantic zero.
        if currentEntry.isRangeExplicit, let range = currentEntry.validRange {
            let zeroBitPattern = currentEntry.choice.semanticSimplest.bitPattern64
            if range.contains(zeroBitPattern) == false {
                return false
            }
            // Micro-opt 2: skip cross-zero when the leaf's current value pins
            // the valid range's boundary. Binary search has already exhausted
            // everything between the boundary and the reduction target; the
            // remaining "simpler" candidates cross-zero would try are all in
            // that already-rejected region. The property has demonstrated
            // that this exact boundary value is required. Saves the full
            // budget of wasted probes per pinned leaf (e.g. Bound5's leaves
            // at `Int16.min`).
            let currentBP = currentEntry.choice.bitPattern64
            if currentBP == range.lowerBound || currentBP == range.upperBound {
                return false
            }
        }

        // Adaptive budget: ⌈log₂(currentKey + 1)⌉ + 4, clamped to [4, 16].
        // Small keys get one probe per key below them (fully exhaustive),
        // large keys get the simplest 16 shortlex keys (0..15).
        let bitLength = UInt64(64 - currentKey.leadingZeroBitCount)
        let budget = min(bitLength + 4, 16)
        let endKey = min(currentKey, budget)

        state.crossZero = CrossZeroState(
            seqIdx: leaf.sequenceIndex,
            tag: leaf.typeTag,
            validRange: currentEntry.validRange,
            isRangeExplicit: currentEntry.isRangeExplicit,
            nextKey: 0,
            endKey: endKey,
            lastEmittedKey: nil
        )
        return true
    }

    /// Drives the cross-zero phase for the current leaf.
    ///
    /// Walks shortlex keys from 0 upward, emitting one candidate per call and exiting on the first acceptance — walking upward guarantees that the first accepted probe is the simplest possible value for this leaf, so there is no benefit to continuing once one is found.
    ///
    /// Returns `nil` when the walk is exhausted (all probes rejected or budget reached) or when the caller should advance to the next leaf (acceptance happened on the prior call). The caller clears ``IntegerState/crossZero`` and advances `leafIndex` when `nil` is returned.
    private mutating func nextCrossZeroProbe(
        state: inout IntegerState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        guard var crossZero = state.crossZero else { return nil }

        // Consume feedback for the previous probe, if any.
        if let acceptedKey = crossZero.lastEmittedKey {
            crossZero.lastEmittedKey = nil
            if lastAccepted {
                // Acceptance — nextIntegerProbe has already advanced
                // state.sequence to the accepted candidate. Record the
                // convergence at the new bit pattern so the next cycle's
                // binary search can warm-start from here, then exit.
                let leaf = state.leafPositions[state.leafIndex]
                let acceptedChoice = ChoiceValue.fromShortlexKey(
                    acceptedKey,
                    tag: crossZero.tag
                )
                convergenceStore[leaf.sequenceIndex] = ConvergedOrigin(
                    bound: acceptedChoice.bitPattern64,
                    signal: .monotoneConvergence,
                    configuration: .binarySearchSemanticSimplest,
                    cycle: 0
                )
                state.crossZero = crossZero
                return nil
            }
            // Rejection — fall through and emit the next probe.
        }

        // Walk upward from `nextKey` looking for a probe that is in range.
        while crossZero.nextKey < crossZero.endKey {
            let probeKey = crossZero.nextKey
            crossZero.nextKey += 1

            let probeChoice = ChoiceValue.fromShortlexKey(probeKey, tag: crossZero.tag)

            // Range validation: when the range is explicitly user-declared,
            // a probe outside it would be rejected by the materializer.
            // Skip rather than waste a property call.
            if crossZero.isRangeExplicit,
               probeChoice.fits(in: crossZero.validRange) == false
            {
                continue
            }

            crossZero.lastEmittedKey = probeKey
            state.crossZero = crossZero

            var candidate = state.sequence
            candidate[crossZero.seqIdx] = .reduced(.init(
                choice: probeChoice,
                validRange: crossZero.validRange,
                isRangeExplicit: crossZero.isRangeExplicit
            ))
            state.lastEmittedCandidate = candidate
            return candidate
        }

        // Exhausted — no further probes to try.
        state.crossZero = crossZero
        return nil
    }

    // MARK: - Float Mode

    private mutating func startFloat(
        scope: FloatMinimizationScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) {
        var targets: [FloatTarget] = []

        for entry in scope.leaves {
            let nodeID = entry.nodeID
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            guard let range = graph.nodes[nodeID].positionRange else { continue }
            guard range.lowerBound < sequence.count,
                  let sequenceEntry = sequence[range.lowerBound].value else { continue }
            guard case let .floating(currentValue, currentBP, _) = sequenceEntry.choice else { continue }
            targets.append(FloatTarget(
                nodeID: nodeID,
                sequenceIndex: range.lowerBound,
                typeTag: metadata.typeTag,
                validRange: metadata.validRange,
                isRangeExplicit: sequenceEntry.isRangeExplicit,
                currentValue: currentValue,
                currentBitPattern: currentBP,
                mayReshape: entry.mayReshapeOnAcceptance
            ))
        }

        mode = .floatLeaves(FloatState(
            sequence: sequence,
            targets: targets,
            currentTargetIndex: 0,
            stage: .specialValues,
            batchCandidates: [],
            batchIndex: 0,
            stepper: FindIntegerStepper(),
            needsFirstProbe: true,
            lastEmittedCandidate: nil,
            binarySearchMinDelta: 1,
            binarySearchMaxQuantum: 0,
            binarySearchMovesUp: false,
            binarySearchCurrentInt: 0,
            ratioDenominator: 0,
            ratioRemainder: 0,
            ratioIntegerPart: 0,
            ratioDistance: 0
        ))
    }

    private mutating func nextFloatProbe(
        state: inout FloatState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        // Update baseline on acceptance.
        if lastAccepted, let accepted = state.lastEmittedCandidate {
            state.sequence = accepted
        }
        state.lastEmittedCandidate = nil

        while state.currentTargetIndex < state.targets.count {
            if state.needsFirstProbe {
                state.needsFirstProbe = false
                prepareFloatStage(state: &state)
            } else if lastAccepted {
                handleFloatAcceptance(state: &state)
            }

            if let candidate = nextFloatCandidateForCurrentStage(
                state: &state,
                lastAccepted: lastAccepted
            ) {
                state.lastEmittedCandidate = candidate
                return candidate
            }

            // Stage exhausted — advance to next stage or next target.
            if advanceFloatStageOrTarget(state: &state) == false {
                return nil
            }
        }
        return nil
    }

    // MARK: - Float Stage Preparation

    private mutating func prepareFloatStage(state: inout FloatState) {
        guard state.currentTargetIndex < state.targets.count else { return }
        let target = state.targets[state.currentTargetIndex]
        state.batchCandidates = []
        state.batchIndex = 0

        switch state.stage {
        case .specialValues:
            prepareFloatSpecialValues(state: &state, target: target)
        case .truncation:
            prepareFloatTruncation(state: &state, target: target)
        case .integralBinarySearch:
            prepareFloatIntegralBinarySearch(state: &state, target: target)
        case .ratioBinarySearch:
            prepareFloatRatioBinarySearch(state: &state, target: target)
        }
    }

    private mutating func prepareFloatSpecialValues(state: inout FloatState, target: FloatTarget) {
        var candidates: [UInt64] = []

        // Try the semantic-simplest target directly.
        guard target.sequenceIndex < state.sequence.count,
              let entry = state.sequence[target.sequenceIndex].value else { return }
        let isWithinRecordedRange = entry.isRangeExplicit && entry.choice.fits(in: entry.validRange)
        let targetBP = isWithinRecordedRange
            ? entry.choice.reductionTarget(in: entry.validRange)
            : entry.choice.semanticSimplest.bitPattern64
        if targetBP != target.currentBitPattern {
            candidates.append(targetBP)
        }

        for special in FloatReduction.specialValues(for: target.typeTag) {
            guard let candidateChoice = floatingChoice(
                from: special,
                tag: target.typeTag,
                allowNonFinite: true
            ) else { continue }
            let bp = candidateChoice.bitPattern64
            if bp != target.currentBitPattern, candidates.contains(bp) == false {
                candidates.append(bp)
            }
        }

        state.batchCandidates = candidates
    }

    private mutating func prepareFloatTruncation(state: inout FloatState, target: FloatTarget) {
        guard target.currentValue.isFinite else {
            state.batchCandidates = []
            return
        }

        var seenBitPatterns = Set<UInt64>()
        var candidates: [UInt64] = []

        for power in 0 ..< 10 {
            let scale = Double(1 << power)
            let scaled = target.currentValue * scale
            guard scaled.isFinite else { continue }

            for truncated in [scaled.rounded(.down), scaled.rounded(.up)] {
                let candidateValue = truncated / scale
                guard candidateValue.isFinite,
                      let candidateChoice = floatingChoice(from: candidateValue, tag: target.typeTag)
                else { continue }
                let bp = candidateChoice.bitPattern64
                guard bp != target.currentBitPattern,
                      seenBitPatterns.insert(bp).inserted
                else { continue }
                candidates.append(bp)
            }
        }

        state.batchCandidates = candidates
    }

    private mutating func prepareFloatIntegralBinarySearch(state: inout FloatState, target: FloatTarget) {
        guard target.currentValue.isFinite,
              target.currentValue == target.currentValue.rounded(.towardZero),
              abs(target.currentValue) <= Double(Int64.max)
        else { return }

        let currentInt = Int64(target.currentValue)
        let targetInt: Int64 = 0
        let movesUp = targetInt > currentInt
        let distance = movesUp
            ? UInt64(targetInt - currentInt)
            : UInt64(currentInt - targetInt)
        guard distance > 1 else { return }

        let currentULP: Double = switch target.typeTag {
        case .double:
            target.currentValue.ulp
        case .float, .float16:
            Double(Float(target.currentValue).ulp)
        default:
            1.0
        }
        guard currentULP.isFinite else { return }
        let minDelta = UInt64(max(1.0, currentULP.rounded(.up)))
        guard minDelta > 0 else { return }
        let maxQuantum = distance / minDelta
        guard maxQuantum > 0 else { return }

        state.binarySearchMinDelta = minDelta
        state.binarySearchMaxQuantum = maxQuantum
        state.binarySearchMovesUp = movesUp
        state.binarySearchCurrentInt = currentInt
    }

    private mutating func prepareFloatRatioBinarySearch(state: inout FloatState, target: FloatTarget) {
        guard target.currentValue.isFinite,
              abs(target.currentValue) <= FloatReduction.maxPreciseInteger(for: target.typeTag),
              let ratio = FloatReduction.integerRatio(for: target.currentValue, tag: target.typeTag)
        else { return }

        guard ratio.denominator > 1, ratio.denominator <= UInt64(Int64.max) else { return }

        let denominator = Int64(ratio.denominator)
        let (integerPart, remainder) = floorDivMod(ratio.numerator, denominator)
        let targetInt: Int64 = 0
        let movesUp = targetInt > integerPart
        let distance = movesUp
            ? UInt64(targetInt - integerPart)
            : UInt64(integerPart - targetInt)
        guard distance > 0 else { return }

        state.ratioDenominator = denominator
        state.ratioRemainder = remainder
        state.ratioIntegerPart = integerPart
        state.ratioDistance = distance
        state.binarySearchMovesUp = movesUp
    }

    // MARK: - Float Candidate Generation

    private mutating func nextFloatCandidateForCurrentStage(
        state: inout FloatState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        switch state.stage {
        case .specialValues, .truncation:
            return nextFloatBatchCandidate(state: &state)
        case .integralBinarySearch:
            return nextFloatIntegralBinarySearchCandidate(state: &state, lastAccepted: lastAccepted)
        case .ratioBinarySearch:
            return nextFloatRatioBinarySearchCandidate(state: &state, lastAccepted: lastAccepted)
        }
    }

    private mutating func nextFloatBatchCandidate(state: inout FloatState) -> ChoiceSequence? {
        guard state.currentTargetIndex < state.targets.count else { return nil }
        let target = state.targets[state.currentTargetIndex]
        while state.batchIndex < state.batchCandidates.count {
            let bp = state.batchCandidates[state.batchIndex]
            state.batchIndex += 1

            guard let candidateChoice = makeFloatChoice(bitPattern: bp, tag: target.typeTag) else {
                continue
            }
            if target.isRangeExplicit, candidateChoice.fits(in: target.validRange) == false {
                continue
            }

            let candidateEntry = ChoiceSequenceValue.value(.init(
                choice: candidateChoice,
                validRange: target.validRange,
                isRangeExplicit: target.isRangeExplicit
            ))
            guard candidateEntry.shortLexCompare(state.sequence[target.sequenceIndex]) == .lt else {
                continue
            }

            var candidate = state.sequence
            candidate[target.sequenceIndex] = candidateEntry
            return candidate
        }
        return nil
    }

    private mutating func nextFloatIntegralBinarySearchCandidate(
        state: inout FloatState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        guard state.binarySearchMaxQuantum > 0 else { return nil }
        let target = state.targets[state.currentTargetIndex]

        let quantum: Int?
        if state.batchIndex == 0 {
            state.batchIndex = 1
            quantum = state.stepper.start()
        } else {
            quantum = state.stepper.advance(lastAccepted: lastAccepted)
        }

        guard let k = quantum else {
            // Converged — apply best accepted if any.
            if state.stepper.bestAccepted > 0 {
                applyFloatIntegralBinarySearchBest(state: &state)
            }
            convergenceStore[target.sequenceIndex] = ConvergedOrigin(
                bound: state.targets[state.currentTargetIndex].currentBitPattern,
                signal: .monotoneConvergence,
                configuration: .binarySearchSemanticSimplest,
                cycle: 0
            )
            return nil
        }

        let kU64 = UInt64(k)
        guard kU64 <= state.binarySearchMaxQuantum else {
            return nextFloatIntegralBinarySearchCandidate(state: &state, lastAccepted: false)
        }
        let delta = kU64 * state.binarySearchMinDelta
        guard delta <= UInt64(Int64.max) else {
            return nextFloatIntegralBinarySearchCandidate(state: &state, lastAccepted: false)
        }
        let signedDelta = Int64(delta)
        let candidateInt = state.binarySearchMovesUp
            ? state.binarySearchCurrentInt + signedDelta
            : state.binarySearchCurrentInt - signedDelta
        let candidateDouble = Double(candidateInt)
        guard let candidateChoice = floatingChoice(from: candidateDouble, tag: target.typeTag) else {
            return nextFloatIntegralBinarySearchCandidate(state: &state, lastAccepted: false)
        }

        if candidateChoice.bitPattern64 == target.currentBitPattern {
            return nextFloatIntegralBinarySearchCandidate(state: &state, lastAccepted: true)
        }

        if target.isRangeExplicit, candidateChoice.fits(in: target.validRange) == false {
            return nextFloatIntegralBinarySearchCandidate(state: &state, lastAccepted: false)
        }

        let candidateEntry = ChoiceSequenceValue.value(.init(
            choice: candidateChoice,
            validRange: target.validRange,
            isRangeExplicit: target.isRangeExplicit
        ))
        guard candidateEntry.shortLexCompare(state.sequence[target.sequenceIndex]) == .lt else {
            return nextFloatIntegralBinarySearchCandidate(state: &state, lastAccepted: false)
        }

        var candidate = state.sequence
        candidate[target.sequenceIndex] = candidateEntry
        return candidate
    }

    private mutating func applyFloatIntegralBinarySearchBest(state: inout FloatState) {
        let target = state.targets[state.currentTargetIndex]
        let bestK = UInt64(state.stepper.bestAccepted)
        let delta = bestK * state.binarySearchMinDelta
        let signedDelta = Int64(delta)
        let candidateInt = state.binarySearchMovesUp
            ? state.binarySearchCurrentInt + signedDelta
            : state.binarySearchCurrentInt - signedDelta
        let candidateDouble = Double(candidateInt)
        guard let candidateChoice = floatingChoice(from: candidateDouble, tag: target.typeTag) else {
            return
        }
        let candidateEntry = ChoiceSequenceValue.value(.init(
            choice: candidateChoice,
            validRange: target.validRange,
            isRangeExplicit: target.isRangeExplicit
        ))
        state.sequence[target.sequenceIndex] = candidateEntry
        state.targets[state.currentTargetIndex].currentValue = candidateDouble
        state.targets[state.currentTargetIndex].currentBitPattern = candidateChoice.bitPattern64
    }

    private mutating func nextFloatRatioBinarySearchCandidate(
        state: inout FloatState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        guard state.ratioDistance > 0 else { return nil }
        let target = state.targets[state.currentTargetIndex]

        let quantum: Int?
        if state.batchIndex == 0 {
            state.batchIndex = 1
            quantum = state.stepper.start()
        } else {
            quantum = state.stepper.advance(lastAccepted: lastAccepted)
        }

        guard let k = quantum else {
            if state.stepper.bestAccepted > 0 {
                applyFloatRatioBinarySearchBest(state: &state)
            }
            convergenceStore[target.sequenceIndex] = ConvergedOrigin(
                bound: state.targets[state.currentTargetIndex].currentBitPattern,
                signal: .monotoneConvergence,
                configuration: .binarySearchSemanticSimplest,
                cycle: 0
            )
            return nil
        }

        let kU64 = UInt64(k)
        guard kU64 <= state.ratioDistance, kU64 <= UInt64(Int64.max) else {
            return nextFloatRatioBinarySearchCandidate(state: &state, lastAccepted: false)
        }
        let signedDelta = Int64(kU64)
        let candidateInteger = state.binarySearchMovesUp
            ? state.ratioIntegerPart + signedDelta
            : state.ratioIntegerPart - signedDelta

        let (scaledNumerator, multiplyOverflow) =
            candidateInteger.multipliedReportingOverflow(by: state.ratioDenominator)
        guard multiplyOverflow == false else {
            return nextFloatRatioBinarySearchCandidate(state: &state, lastAccepted: false)
        }
        let (candidateNumerator, addOverflow) =
            scaledNumerator.addingReportingOverflow(state.ratioRemainder)
        guard addOverflow == false else {
            return nextFloatRatioBinarySearchCandidate(state: &state, lastAccepted: false)
        }

        let candidateValue = Double(candidateNumerator) / Double(state.ratioDenominator)
        guard let candidateChoice = floatingChoice(from: candidateValue, tag: target.typeTag) else {
            return nextFloatRatioBinarySearchCandidate(state: &state, lastAccepted: false)
        }

        if candidateChoice.bitPattern64 == target.currentBitPattern {
            return nextFloatRatioBinarySearchCandidate(state: &state, lastAccepted: true)
        }

        if target.isRangeExplicit, candidateChoice.fits(in: target.validRange) == false {
            return nextFloatRatioBinarySearchCandidate(state: &state, lastAccepted: false)
        }

        let candidateEntry = ChoiceSequenceValue.value(.init(
            choice: candidateChoice,
            validRange: target.validRange,
            isRangeExplicit: target.isRangeExplicit
        ))
        guard candidateEntry.shortLexCompare(state.sequence[target.sequenceIndex]) == .lt else {
            return nextFloatRatioBinarySearchCandidate(state: &state, lastAccepted: false)
        }

        var candidate = state.sequence
        candidate[target.sequenceIndex] = candidateEntry
        return candidate
    }

    private mutating func applyFloatRatioBinarySearchBest(state: inout FloatState) {
        let target = state.targets[state.currentTargetIndex]
        let bestK = UInt64(state.stepper.bestAccepted)
        let signedDelta = Int64(bestK)
        let candidateInteger = state.binarySearchMovesUp
            ? state.ratioIntegerPart + signedDelta
            : state.ratioIntegerPart - signedDelta

        let scaledNumerator = candidateInteger * state.ratioDenominator
        let candidateNumerator = scaledNumerator + state.ratioRemainder
        let candidateValue = Double(candidateNumerator) / Double(state.ratioDenominator)
        guard let candidateChoice = floatingChoice(from: candidateValue, tag: target.typeTag) else {
            return
        }
        let candidateEntry = ChoiceSequenceValue.value(.init(
            choice: candidateChoice,
            validRange: target.validRange,
            isRangeExplicit: target.isRangeExplicit
        ))
        state.sequence[target.sequenceIndex] = candidateEntry
        state.targets[state.currentTargetIndex].currentValue = candidateValue
        state.targets[state.currentTargetIndex].currentBitPattern = candidateChoice.bitPattern64
    }

    // MARK: - Float Acceptance & Advancement

    private mutating func handleFloatAcceptance(state: inout FloatState) {
        let target = state.targets[state.currentTargetIndex]
        switch state.stage {
        case .specialValues, .truncation:
            // Batch stages: the last emitted candidate was accepted.
            // Update target and restart from stage 0 on the next target.
            let bp = state.batchCandidates[state.batchIndex - 1]
            if let choice = makeFloatChoice(bitPattern: bp, tag: target.typeTag) {
                let entry = ChoiceSequenceValue.value(.init(
                    choice: choice,
                    validRange: target.validRange,
                    isRangeExplicit: target.isRangeExplicit
                ))
                state.sequence[target.sequenceIndex] = entry
                if case let .floating(value, _, _) = choice {
                    state.targets[state.currentTargetIndex].currentValue = value
                }
                state.targets[state.currentTargetIndex].currentBitPattern = bp
            }
            state.currentTargetIndex += 1
            state.stage = .specialValues
            state.needsFirstProbe = true
        case .integralBinarySearch, .ratioBinarySearch:
            // Stepper handles acceptance via advance(lastAccepted:).
            break
        }
    }

    @discardableResult
    private mutating func advanceFloatStageOrTarget(state: inout FloatState) -> Bool {
        let nextStage: FloatStage? = switch state.stage {
        case .specialValues: .truncation
        case .truncation: .integralBinarySearch
        case .integralBinarySearch: .ratioBinarySearch
        case .ratioBinarySearch: nil
        }

        if let next = nextStage {
            state.stage = next
            state.batchIndex = 0
            state.batchCandidates = []
            state.stepper = FindIntegerStepper()
            state.needsFirstProbe = true
            guard state.currentTargetIndex < state.targets.count else { return false }
            prepareFloatStage(state: &state)
            return true
        }

        // All stages exhausted for this target — move to next.
        state.currentTargetIndex += 1
        state.stage = .specialValues
        state.batchIndex = 0
        state.batchCandidates = []
        state.stepper = FindIntegerStepper()
        state.needsFirstProbe = true
        if state.currentTargetIndex < state.targets.count {
            prepareFloatStage(state: &state)
        }
        return state.currentTargetIndex < state.targets.count
    }

    // MARK: - Float Helpers

    private func floatingChoice(
        from value: Double,
        tag: TypeTag,
        allowNonFinite: Bool = false
    ) -> ChoiceValue? {
        switch tag {
        case .double:
            guard allowNonFinite || value.isFinite else { return nil }
            return ChoiceValue(value, tag: .double)
        case .float:
            let narrowed = Float(value)
            guard allowNonFinite || narrowed.isFinite else { return nil }
            return ChoiceValue(narrowed, tag: .float)
        case .float16:
            let encoded = Float16Emulation.encodedBitPattern(from: value)
            let reconstructed = Float16Emulation.doubleValue(fromEncoded: encoded)
            guard allowNonFinite || reconstructed.isFinite else { return nil }
            return .floating(reconstructed, encoded, .float16)
        default:
            return nil
        }
    }

    private func makeFloatChoice(bitPattern: UInt64, tag: TypeTag) -> ChoiceValue? {
        ChoiceValue(tag.makeConvertible(bitPattern64: bitPattern), tag: tag)
    }

    private func floorDivMod(
        _ numerator: Int64,
        _ denominator: Int64
    ) -> (quotient: Int64, remainder: Int64) {
        precondition(denominator > 0)
        var quotient = numerator / denominator
        var remainder = numerator % denominator
        if remainder < 0 {
            quotient -= 1
            remainder += denominator
        }
        return (quotient, remainder)
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
