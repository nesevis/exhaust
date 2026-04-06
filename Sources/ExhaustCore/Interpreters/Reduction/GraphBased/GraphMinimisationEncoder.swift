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
        let leafPositions: [(nodeID: Int, sequenceIndex: Int, validRange: ClosedRange<UInt64>?, currentBitPattern: UInt64, targetBitPattern: UInt64, typeTag: TypeTag)]
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

    private struct FloatState {
        var sequence: ChoiceSequence
        let leafPositions: [(nodeID: Int, sequenceIndex: Int, validRange: ClosedRange<UInt64>?, typeTag: TypeTag)]
        var leafIndex: Int
        var triedSimplest: Bool
        var lastEmittedCandidate: ChoiceSequence?
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

    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        switch mode {
        case .idle, .kleisliFibre:
            return nil
        case var .integerLeaves(state):
            let result = nextIntegerProbe(state: &state, lastAccepted: lastAccepted)
            mode = .integerLeaves(state)
            return result
        case var .floatLeaves(state):
            let result = nextFloatProbe(state: &state, lastAccepted: lastAccepted)
            mode = .floatLeaves(state)
            return result
        }
    }

    // MARK: - Integer Mode

    private mutating func startInteger(
        scope: IntegerMinimizationScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph,
        warmStarts: [Int: ConvergedOrigin]
    ) {
        var leafPositions: [(nodeID: Int, sequenceIndex: Int, validRange: ClosedRange<UInt64>?, currentBitPattern: UInt64, targetBitPattern: UInt64, typeTag: TypeTag)] = []

        for nodeID in scope.leafNodeIDs {
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
                    typeTag: metadata.typeTag
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
            scanBestAccepted: nil
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
            // Linear scan phase (set up by binary search on non-monotone gap).
            if state.scanValues != nil {
                if let candidate = nextLinearScanProbe(
                    state: &state,
                    lastAccepted: lastAccepted
                ) {
                    return candidate
                }
                // Scan exhausted — record convergence and move to next leaf.
                finishLinearScan(state: &state)
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
            // to drain it. Otherwise move to next leaf.
            if state.scanValues != nil {
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

    // MARK: - Float Mode

    private mutating func startFloat(
        scope: FloatMinimizationScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) {
        var leafPositions: [(nodeID: Int, sequenceIndex: Int, validRange: ClosedRange<UInt64>?, typeTag: TypeTag)] = []

        for nodeID in scope.leafNodeIDs {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            guard let range = graph.nodes[nodeID].positionRange else { continue }
            leafPositions.append((
                nodeID: nodeID,
                sequenceIndex: range.lowerBound,
                validRange: metadata.validRange,
                typeTag: metadata.typeTag
            ))
        }

        mode = .floatLeaves(FloatState(
            sequence: sequence,
            leafPositions: leafPositions,
            leafIndex: 0,
            triedSimplest: false,
            lastEmittedCandidate: nil
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

        // Simplified float handling: try semantic simplest for each leaf.
        // The full four-stage IEEE 754 pipeline will be ported in a later pass.
        while state.leafIndex < state.leafPositions.count {
            let leaf = state.leafPositions[state.leafIndex]
            if state.triedSimplest == false {
                state.triedSimplest = true
                let target = ChoiceValue(.zero as Double, tag: leaf.typeTag)
                    .reductionTarget(in: leaf.validRange)
                var candidate = state.sequence
                candidate[leaf.sequenceIndex] = candidate[leaf.sequenceIndex]
                    .withBitPattern(target)
                if candidate.shortLexPrecedes(state.sequence) {
                    state.lastEmittedCandidate = candidate
                    return candidate
                }
            }
            state.leafIndex += 1
            state.triedSimplest = false
        }
        return nil
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
