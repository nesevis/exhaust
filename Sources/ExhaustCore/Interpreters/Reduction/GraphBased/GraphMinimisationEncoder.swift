//
//  GraphMinimisationEncoder.swift
//  Exhaust
//

// MARK: - Graph Minimisation Encoder

/// Drives leaf values toward their semantic simplest without changing graph structure.
///
/// Operates in three modes based on the ``MinimisationScope``:
/// - **Integer leaves**: batch zeroing attempt followed by per-leaf binary search via ``BinarySearchStepper``, with cross-zero phase for signed integers.
/// - **Float leaves**: four-stage IEEE 754 pipeline (special values, truncation, integral binary search, ratio binary search).
/// - **Kleisli fibre**: joint upstream/downstream minimisation along a dependency edge. Internally a Kleisli composition — each upstream probe spawns a downstream search.
///
/// This is an active-path operation: all leaves have position ranges in the current sequence. Candidates are constructed by modifying leaf values at pre-resolved positions.
struct GraphMinimisationEncoder: GraphEncoder {
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

        guard case let .minimisation(minimisationScope) = scope.transformation.operation else {
            mode = .idle
            return
        }

        let sequence = scope.baseSequence
        let graph = scope.graph

        switch minimisationScope {
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
        scope: IntegerMinimisationScope,
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
            lastEmittedCandidate: nil
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
            // Batch zero rejected — fall through to per-leaf.
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
                // Initialize stepper for this leaf. Use the CURRENT value from
                // the baseline sequence (which may have been updated by prior
                // acceptances) rather than the original value from the scope.
                let currentEntry = state.sequence[leaf.sequenceIndex]
                let currentBitPattern = currentEntry.value?.choice.bitPattern64 ?? leaf.currentBitPattern
                let lo = leaf.targetBitPattern
                let hi = currentBitPattern > leaf.targetBitPattern
                    ? currentBitPattern
                    : leaf.targetBitPattern

                guard lo != hi else {
                    // Already at target — skip.
                    state.leafIndex += 1
                    continue
                }

                // Check warm-start.
                if let warmStart = state.warmStartRecords[leaf.sequenceIndex],
                   warmStart.configuration == .binarySearchSemanticSimplest {
                    let warmLo = min(warmStart.bound, hi)
                    state.stepper = BinarySearchStepper(lo: warmLo, hi: hi)
                } else {
                    state.stepper = BinarySearchStepper(lo: lo, hi: hi)
                }

                guard let firstValue = state.stepper?.start() else {
                    state.leafIndex += 1
                    state.stepper = nil
                    continue
                }

                var candidate = state.sequence
                candidate[leaf.sequenceIndex] = candidate[leaf.sequenceIndex]
                    .withBitPattern(firstValue)
                if candidate.shortLexPrecedes(state.sequence) {
                    state.lastEmittedCandidate = candidate
                    return candidate
                }
                // First probe not shortlex-better — advance.
            }

            if let nextValue = state.stepper?.advance(lastAccepted: lastAccepted) {
                var candidate = state.sequence
                candidate[leaf.sequenceIndex] = candidate[leaf.sequenceIndex]
                    .withBitPattern(nextValue)
                if candidate.shortLexPrecedes(state.sequence) {
                    state.lastEmittedCandidate = candidate
                    return candidate
                }
                continue
            }

            // Stepper converged — record convergence and move to next leaf.
            if let bestAccepted = state.stepper?.bestAccepted {
                convergenceStore[leaf.sequenceIndex] = ConvergedOrigin(
                    bound: bestAccepted,
                    signal: .monotoneConvergence,
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
        scope: FloatMinimisationScope,
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
    func withBitPattern(_ bitPattern: UInt64) -> ChoiceSequenceValue {
        switch self {
        case let .value(value):
            let newChoice = ChoiceValue(
                value.choice.tag.makeConvertible(bitPattern64: bitPattern),
                tag: value.choice.tag
            )
            return .value(.init(
                choice: newChoice,
                validRange: value.validRange,
                isRangeExplicit: value.isRangeExplicit
            ))
        case let .reduced(value):
            let newChoice = ChoiceValue(
                value.choice.tag.makeConvertible(bitPattern64: bitPattern),
                tag: value.choice.tag
            )
            return .reduced(.init(
                choice: newChoice,
                validRange: value.validRange,
                isRangeExplicit: value.isRangeExplicit
            ))
        default:
            return self
        }
    }
}
