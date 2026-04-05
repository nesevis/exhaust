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
        var leafPhase: LeafPhase
        var warmStartRecords: [Int: ConvergedOrigin]
        /// The last candidate emitted by nextProbe. When lastAccepted is true, this becomes the new baseline sequence.
        var lastEmittedCandidate: ChoiceSequence?
        /// Whether the batch-zero probe was rejected. When true and a leaf individually converges at its target, the convergence signal is `zeroingDependency` instead of `monotoneConvergence`.
        var batchRejected: Bool
    }

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

    /// Per-leaf search phase within the binary-search-then-cross-zero pipeline.
    private enum LeafPhase {
        /// Binary search in bit-pattern space (directional).
        case binarySearch
        /// Cross-zero phase for signed types: walks shortlex keys downward from the converged value to find simpler values across the zero boundary.
        case crossZero(currentKey: UInt64, lowerBound: UInt64)
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
            leafPhase: .binarySearch,
            warmStartRecords: warmStarts,
            lastEmittedCandidate: nil,
            batchRejected: false
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
            switch state.leafPhase {
            case .binarySearch:
                if let candidate = nextBitPatternSearchProbe(
                    state: &state,
                    lastAccepted: lastAccepted
                ) {
                    return candidate
                }
                // Binary search converged or was skipped. If leafPhase
                // was set to crossZero, re-enter the loop for that phase.
                if case .crossZero = state.leafPhase {
                    continue
                }
                state.leafIndex += 1
                state.leafPhase = .binarySearch

            case .crossZero(var currentKey, let lowerBound):
                if let candidate = nextCrossZeroProbe(
                    state: &state,
                    currentKey: &currentKey,
                    lowerBound: lowerBound,
                    lastAccepted: lastAccepted
                ) {
                    state.leafPhase = .crossZero(
                        currentKey: currentKey,
                        lowerBound: lowerBound
                    )
                    return candidate
                }
                state.leafIndex += 1
                state.leafPhase = .binarySearch
            }
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

            if currentBP > targetBP {
                state.stepper = .downward(
                    BinarySearchStepper(lo: targetBP, hi: currentBP)
                )
            } else {
                state.stepper = .upward(
                    MaxBinarySearchStepper(lo: currentBP, hi: targetBP)
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

        // Stepper converged — record convergence.
        if let bestAccepted = state.stepper?.bestAccepted {
            let signal: ConvergenceSignal =
                state.batchRejected && bestAccepted == leaf.targetBitPattern
                    ? .zeroingDependency
                    : .monotoneConvergence
            convergenceStore[leaf.sequenceIndex] = ConvergedOrigin(
                bound: bestAccepted,
                signal: signal,
                configuration: .binarySearchSemanticSimplest,
                cycle: 0
            )
        }
        state.stepper = nil

        // Enter cross-zero phase for signed types.
        if leaf.typeTag.isSigned {
            guard let currentChoice = state.sequence[leaf.sequenceIndex].value?.choice else {
                return nil
            }
            let currentKey = currentChoice.shortlexKey
            if currentKey > 0 {
                let maxCrossZeroProbes: UInt64 = 16
                let lowerBound = currentKey > maxCrossZeroProbes
                    ? currentKey - maxCrossZeroProbes
                    : 0
                state.leafPhase = .crossZero(
                    currentKey: currentKey,
                    lowerBound: lowerBound
                )
            }
        }

        return nil
    }

    // MARK: - Cross-Zero Phase

    /// Walks shortlex keys downward from the binary search convergence point to find simpler values across the zero boundary.
    ///
    /// For signed types, the bit-pattern binary search converges on one side of zero. The cross-zero phase tries values with smaller shortlex keys (closer to zero in magnitude) that may be on the opposite side. Capped at 16 probes per leaf.
    private mutating func nextCrossZeroProbe(
        state: inout IntegerState,
        currentKey: inout UInt64,
        lowerBound: UInt64,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        let leaf = state.leafPositions[state.leafIndex]

        guard currentKey > lowerBound else { return nil }

        let nextKey = currentKey - 1
        currentKey = nextKey

        let probeChoice = ChoiceValue.fromShortlexKey(nextKey, tag: leaf.typeTag)
        let probeBP = probeChoice.bitPattern64

        // Skip if out of valid range.
        if let validRange = leaf.validRange {
            guard validRange.contains(probeBP) else {
                return nextCrossZeroProbe(
                    state: &state,
                    currentKey: &currentKey,
                    lowerBound: lowerBound,
                    lastAccepted: false
                )
            }
        }

        var candidate = state.sequence
        candidate[leaf.sequenceIndex] = candidate[leaf.sequenceIndex]
            .withBitPattern(probeBP)
        guard candidate.shortLexPrecedes(state.sequence) else {
            return nextCrossZeroProbe(
                state: &state,
                currentKey: &currentKey,
                lowerBound: lowerBound,
                lastAccepted: false
            )
        }

        state.lastEmittedCandidate = candidate
        return candidate
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
