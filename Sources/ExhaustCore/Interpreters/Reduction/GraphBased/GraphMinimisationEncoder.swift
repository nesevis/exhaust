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
        let leafPositions: [(nodeID: Int, sequenceIndex: Int, validRange: ClosedRange<UInt64>?, currentBitPattern: UInt64, targetBitPattern: UInt64)]
        var phase: IntegerPhase
        var leafIndex: Int
        var stepper: BinarySearchStepper?
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
        var leafPositions: [(nodeID: Int, sequenceIndex: Int, validRange: ClosedRange<UInt64>?, currentBitPattern: UInt64, targetBitPattern: UInt64)] = []

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
                    targetBitPattern: target
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
            let leaf = state.leafPositions[state.leafIndex]

            if state.stepper == nil {
                // Initialize stepper for this leaf in SHORTLEX KEY space.
                // Zigzag encoding maps signed values so that values closer
                // to zero have smaller keys: 0→0, -1→1, 1→2, -2→3, ...
                // Binary search in key space naturally finds the simplest
                // predicate-preserving value across the zero boundary.
                let currentEntry = state.sequence[leaf.sequenceIndex]
                guard let currentChoice = currentEntry.value?.choice else {
                    state.leafIndex += 1
                    continue
                }
                let currentKey = currentChoice.shortlexKey
                let targetKey: UInt64 = 0 // shortlex key 0 = semantic simplest

                guard currentKey != targetKey else {
                    state.leafIndex += 1
                    continue
                }

                // Stepper searches from targetKey (0) up to currentKey.
                state.stepper = BinarySearchStepper(lo: targetKey, hi: currentKey)

                guard let firstKey = state.stepper?.start() else {
                    state.leafIndex += 1
                    state.stepper = nil
                    continue
                }

                let probeChoice = ChoiceValue.fromShortlexKey(firstKey, tag: currentChoice.tag)
                var candidate = state.sequence
                candidate[leaf.sequenceIndex] = candidate[leaf.sequenceIndex]
                    .withBitPattern(probeChoice.bitPattern64)
                if candidate.shortLexPrecedes(state.sequence) {
                    state.lastEmittedCandidate = candidate
                    return candidate
                }
            }

            if let nextKey = state.stepper?.advance(lastAccepted: lastAccepted) {
                guard let currentChoice = state.sequence[leaf.sequenceIndex].value?.choice else {
                    continue
                }
                let probeChoice = ChoiceValue.fromShortlexKey(nextKey, tag: currentChoice.tag)
                var candidate = state.sequence
                candidate[leaf.sequenceIndex] = candidate[leaf.sequenceIndex]
                    .withBitPattern(probeChoice.bitPattern64)
                if candidate.shortLexPrecedes(state.sequence) {
                    state.lastEmittedCandidate = candidate
                    return candidate
                }
                continue
            }

            // Stepper converged (in shortlex key space) — record convergence.
            if let bestAcceptedKey = state.stepper?.bestAccepted {
                // Convert shortlex key back to bit pattern for convergence record.
                guard let currentChoice = state.sequence[leaf.sequenceIndex].value?.choice else {
                    state.stepper = nil
                    state.leafIndex += 1
                    continue
                }
                let convergedChoice = ChoiceValue.fromShortlexKey(bestAcceptedKey, tag: currentChoice.tag)
                let convergedBitPattern = convergedChoice.bitPattern64

                let signal: ConvergenceSignal =
                    state.batchRejected && bestAcceptedKey == 0
                        ? .zeroingDependency
                        : .monotoneConvergence
                convergenceStore[leaf.sequenceIndex] = ConvergedOrigin(
                    bound: convergedBitPattern,
                    signal: signal,
                    configuration: .binarySearchSemanticSimplest,
                    cycle: 0
                )
            }
            state.stepper = nil
            state.leafIndex += 1
        }

        return nil
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
