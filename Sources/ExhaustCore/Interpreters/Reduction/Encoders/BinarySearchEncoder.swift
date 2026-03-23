//
//  BinarySearchEncoder.swift
//  Exhaust
//
//  Created by Chris Kolbu on 23/3/2026.
//

/// Binary-searches each target value toward a reduction target, with configurable direction and cross-zero support.
///
/// Two configurations:
/// - ``Configuration/rangeMinimum``: downward-only search toward each value's range minimum (or semantic simplest if outside recorded range). No cross-zero phase.
/// - ``Configuration/semanticSimplest``: bidirectional search (downward or upward depending on relative position). After convergence, a cross-zero phase walks shortlex key space to find simpler signed values.
///
/// This encoder unifies `BinarySearchToRangeMinimumEncoder` and `BinarySearchToSemanticSimplestEncoder`.
public struct BinarySearchEncoder: ComposableEncoder {
    /// Determines search direction and whether cross-zero probes run after convergence.
    public enum Configuration {
        /// Downward binary search toward range minimum. Skips targets where the current value is already below the target. No cross-zero phase.
        case rangeMinimum
        /// Bidirectional binary search toward semantic simplest. After convergence, walks shortlex key space downward for signed integers to find simpler values that bit-pattern search cannot reach.
        case semanticSimplest
    }

    public let configuration: Configuration
    public private(set) var convergenceRecords: [Int: ConvergedOrigin] = [:]

    public var name: EncoderName {
        switch configuration {
        case .rangeMinimum: .binarySearchToRangeMinimum
        case .semanticSimplest: .binarySearchToSemanticSimplest
        }
    }

    public let phase = ReductionPhase.valueMinimization

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: - ComposableEncoder

    public func estimatedCost(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) -> Int? {
        let spans = Self.extractFilteredSpans(from: sequence, in: positionRange, context: context)
        guard spans.isEmpty == false else { return nil }
        return spans.count * costPerTarget
    }

    public mutating func start(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) {
        let spans = Self.extractFilteredSpans(from: sequence, in: positionRange, context: context)
        start(sequence: sequence, targets: .spans(spans), convergedOrigins: context.convergedOrigins)
    }

    // MARK: - State

    private enum DirectionalStepper {
        case downward(BinarySearchStepper)
        case upward(MaxBinarySearchStepper)

        var bestAccepted: UInt64 {
            switch self {
            case let .downward(stepper): stepper.bestAccepted
            case let .upward(stepper): stepper.bestAccepted
            }
        }

        var direction: ConvergedOrigin.Direction {
            switch self {
            case .downward: .downward
            case .upward: .upward
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

    private struct TargetState {
        let seqIdx: Int
        let validRange: ClosedRange<UInt64>?
        let isRangeExplicit: Bool
        let choiceTag: TypeTag
        let targetBP: UInt64
        var stepper: DirectionalStepper
        let isConvergedOrigined: Bool
        let convergedOriginBound: UInt64
    }

    private enum SearchPhase {
        case binarySearch
        case validatingFloor(floor: UInt64, targetBP: UInt64)
        case crossZero(currentKey: UInt64, lowerBound: UInt64)
    }

    private var sequence = ChoiceSequence()
    private var targets: [TargetState] = []
    private var currentIndex = 0
    private var needsFirstProbe = true
    private var searchPhase = SearchPhase.binarySearch
    private var savedEntry: ChoiceSequenceValue?

    private var costPerTarget: Int {
        switch configuration {
        case .rangeMinimum: 64
        case .semanticSimplest: 80
        }
    }

    // MARK: - Start

    public mutating func start(sequence: ChoiceSequence, targets: TargetSet, convergedOrigins: [Int: ConvergedOrigin]? = nil) {
        self.sequence = sequence
        self.targets = []
        currentIndex = 0
        needsFirstProbe = true
        searchPhase = .binarySearch
        savedEntry = nil
        convergenceRecords = [:]

        guard case let .spans(spans) = targets else { return }

        var index = 0
        while index < spans.count {
            let seqIdx = spans[index].range.lowerBound
            guard let value = sequence[seqIdx].value else { index += 1; continue }
            if value.choice.tag == .float || value.choice.tag == .double { index += 1; continue }
            let currentBP = value.choice.bitPattern64
            let isWithinRecordedRange = value.isRangeExplicit && value.choice.fits(in: value.validRange)
            let targetBP = isWithinRecordedRange
                ? value.choice.reductionTarget(in: value.validRange)
                : value.choice.semanticSimplest.bitPattern64
            guard currentBP != targetBP else { index += 1; continue }

            // In rangeMinimum mode, only search downward — skip targets below the current value.
            if configuration == .rangeMinimum, currentBP < targetBP { index += 1; continue }

            let convergedOrigin = convergedOrigins?[seqIdx]
            let isConvergedOrigined: Bool
            let effectiveBound: UInt64
            let stepper: DirectionalStepper

            if currentBP > targetBP {
                let validConvergedOrigin = (convergedOrigin?.direction == .downward) ? convergedOrigin : nil
                effectiveBound = validConvergedOrigin?.bound ?? targetBP
                isConvergedOrigined = validConvergedOrigin != nil
                stepper = .downward(BinarySearchStepper(lo: effectiveBound, hi: currentBP))
            } else {
                let validConvergedOrigin = (convergedOrigin?.direction == .upward) ? convergedOrigin : nil
                effectiveBound = validConvergedOrigin?.bound ?? targetBP
                isConvergedOrigined = validConvergedOrigin != nil
                stepper = .upward(MaxBinarySearchStepper(lo: currentBP, hi: effectiveBound))
            }

            self.targets.append(TargetState(
                seqIdx: seqIdx,
                validRange: value.validRange,
                isRangeExplicit: value.isRangeExplicit,
                choiceTag: value.choice.tag,
                targetBP: targetBP,
                stepper: stepper,
                isConvergedOrigined: isConvergedOrigined,
                convergedOriginBound: effectiveBound
            ))
            index += 1
        }
    }

    // MARK: - Probe Loop

    public mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        while currentIndex < targets.count {
            switch searchPhase {
            case .binarySearch:
                if let candidate = advanceBinarySearch(lastAccepted: lastAccepted) {
                    return candidate
                }
                let convergedTarget = targets[currentIndex]
                convergenceRecords[convergedTarget.seqIdx] = ConvergedOrigin(
                    bound: convergedTarget.stepper.bestAccepted,
                    direction: convergedTarget.stepper.direction
                )
                // Validation probe for warm-started downward search.
                let state = targets[currentIndex]
                if state.isConvergedOrigined,
                   case .downward = state.stepper,
                   state.convergedOriginBound > state.targetBP,
                   state.convergedOriginBound > 0,
                   state.convergedOriginBound < sequence[state.seqIdx].value?.choice.bitPattern64 ?? 0
                {
                    searchPhase = .validatingFloor(
                        floor: state.convergedOriginBound,
                        targetBP: state.targetBP
                    )
                    savedEntry = sequence[state.seqIdx]
                    let probeBP = state.convergedOriginBound - 1
                    sequence[state.seqIdx] = .value(.init(
                        choice: ChoiceValue(state.choiceTag.makeConvertible(bitPattern64: probeBP), tag: state.choiceTag),
                        validRange: state.validRange,
                        isRangeExplicit: state.isRangeExplicit
                    ))
                    return sequence
                }
                // Cross-zero phase: only for semanticSimplest configuration on signed types.
                if tryCrossZeroEntry(for: state) {
                    continue
                }
                advanceToNextTarget()

            case let .validatingFloor(floor, targetBP):
                if lastAccepted {
                    if let saved = savedEntry {
                        sequence[targets[currentIndex].seqIdx] = saved
                        savedEntry = nil
                    }
                    let state = targets[currentIndex]
                    targets[currentIndex] = TargetState(
                        seqIdx: state.seqIdx,
                        validRange: state.validRange,
                        isRangeExplicit: state.isRangeExplicit,
                        choiceTag: state.choiceTag,
                        targetBP: state.targetBP,
                        stepper: .downward(BinarySearchStepper(lo: targetBP, hi: floor - 1)),
                        isConvergedOrigined: false,
                        convergedOriginBound: targetBP
                    )
                    needsFirstProbe = true
                    searchPhase = .binarySearch
                    continue
                }
                if let saved = savedEntry {
                    sequence[targets[currentIndex].seqIdx] = saved
                    savedEntry = nil
                }
                let state = targets[currentIndex]
                if tryCrossZeroEntry(for: state) {
                    continue
                }
                advanceToNextTarget()

            case let .crossZero(currentKey, lowerBound):
                if let saved = savedEntry {
                    if lastAccepted {
                        let state = targets[currentIndex]
                        let acceptedChoice = ChoiceValue.fromShortlexKey(currentKey, tag: state.choiceTag)
                        sequence[state.seqIdx] = .reduced(.init(
                            choice: acceptedChoice,
                            validRange: state.validRange,
                            isRangeExplicit: state.isRangeExplicit
                        ))
                    } else {
                        sequence[targets[currentIndex].seqIdx] = saved
                    }
                    savedEntry = nil
                }
                guard currentKey > lowerBound else {
                    advanceToNextTarget()
                    continue
                }
                let nextKey = currentKey - 1
                searchPhase = .crossZero(currentKey: nextKey, lowerBound: lowerBound)
                let state = targets[currentIndex]
                let probeChoice = ChoiceValue.fromShortlexKey(nextKey, tag: state.choiceTag)
                if state.isRangeExplicit, probeChoice.fits(in: state.validRange) == false {
                    continue
                }
                let probeEntry = ChoiceSequenceValue.reduced(.init(
                    choice: probeChoice,
                    validRange: state.validRange,
                    isRangeExplicit: state.isRangeExplicit
                ))
                guard probeEntry.shortLexCompare(sequence[state.seqIdx]) == .lt else {
                    continue
                }
                savedEntry = sequence[state.seqIdx]
                sequence[state.seqIdx] = probeEntry
                return sequence
            }
        }
        return nil
    }

    // MARK: - Helpers

    private mutating func advanceBinarySearch(lastAccepted: Bool) -> ChoiceSequence? {
        let probeValue: UInt64?

        if needsFirstProbe {
            needsFirstProbe = false
            probeValue = targets[currentIndex].stepper.start()
        } else {
            let state = targets[currentIndex]
            if lastAccepted {
                sequence[state.seqIdx] = .value(.init(
                    choice: ChoiceValue(state.choiceTag.makeConvertible(bitPattern64: state.stepper.bestAccepted), tag: state.choiceTag),
                    validRange: state.validRange,
                    isRangeExplicit: state.isRangeExplicit
                ))
            } else if let saved = savedEntry {
                sequence[state.seqIdx] = saved
            }
            savedEntry = nil
            probeValue = targets[currentIndex].stepper.advance(lastAccepted: lastAccepted)
        }

        guard let bitPattern = probeValue else { return nil }
        let state = targets[currentIndex]
        if let current = sequence[state.seqIdx].value, bitPattern == current.choice.bitPattern64 {
            return nil
        }
        savedEntry = sequence[state.seqIdx]
        sequence[state.seqIdx] = .value(.init(
            choice: ChoiceValue(state.choiceTag.makeConvertible(bitPattern64: bitPattern), tag: state.choiceTag),
            validRange: state.validRange,
            isRangeExplicit: state.isRangeExplicit
        ))
        return sequence
    }

    /// Attempts to enter the cross-zero phase for the given target. Returns true if cross-zero was entered (caller should `continue` the probe loop); false if not applicable.
    private mutating func tryCrossZeroEntry(for state: TargetState) -> Bool {
        guard configuration == .semanticSimplest,
              state.choiceTag.isSigned
        else { return false }
        if state.isConvergedOrigined {
            let currentBP = sequence[state.seqIdx].value?.choice.bitPattern64 ?? 0
            if currentBP == state.convergedOriginBound {
                return false
            }
        }
        let currentChoice = sequence[state.seqIdx].value?.choice ?? ChoiceValue(
            state.choiceTag.makeConvertible(bitPattern64: state.stepper.bestAccepted),
            tag: state.choiceTag
        )
        let currentKey = currentChoice.shortlexKey
        guard currentKey > 0 else { return false }
        let maxProbes: UInt64 = 16
        let lowerBound = currentKey > maxProbes ? currentKey - maxProbes : 0
        searchPhase = .crossZero(currentKey: currentKey, lowerBound: lowerBound)
        return true
    }

    private mutating func advanceToNextTarget() {
        currentIndex += 1
        needsFirstProbe = true
        searchPhase = .binarySearch
    }
}
