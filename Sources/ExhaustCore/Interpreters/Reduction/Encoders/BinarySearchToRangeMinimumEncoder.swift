//
//  BinarySearchToRangeMinimumEncoder.swift
//  Exhaust
//
//  Created by Chris Kolbu on 14/3/2026.
//

/// Binary-searches each target value toward a specific reduction target.
///
/// The reduction target for each value is determined by its recorded valid range (see ``ChoiceValue/reductionTarget(in:)``). Processes targets sequentially, converging each via ``BinarySearchStepper`` before moving to the next.
public struct BinarySearchToRangeMinimumEncoder: AdaptiveEncoder {
    public init() {}

    public private(set) var convergenceRecords: [Int: ConvergedOrigin] = [:]

    public let name: EncoderName = .binarySearchToRangeMinimum
    public let phase = ReductionPhase.valueMinimization

    public func estimatedCost(sequence: ChoiceSequence, bindIndex _: BindSpanIndex?) -> Int? {
        let t = ChoiceSequence.extractAllValueSpans(from: sequence).count
        guard t > 0 else { return nil }
        // t targets × ~64: BinarySearchStepper over [reductionTarget, currentBP] converges in O(log(range)) steps, bounded by the reduction target rather than zero.
        return t * 64
    }

    // MARK: - State

    private struct TargetState {
        let seqIdx: Int
        let validRange: ClosedRange<UInt64>?
        let isRangeExplicit: Bool
        let choiceTag: TypeTag
        let targetBP: UInt64
        var stepper: BinarySearchStepper
        let isConvergedOrigined: Bool
        let convergedOriginBound: UInt64
    }

    private var sequence = ChoiceSequence()
    private var targets: [TargetState] = []
    private var currentIndex = 0
    private var needsFirstProbe = true
    /// Saved entry for in-place mutation restore on rejection.
    private var savedEntry: ChoiceSequenceValue?
    /// Pending validation probe state: after warm-started convergence, emits one probe at floor - 1.
    private var pendingValidation: (seqIdx: Int, floor: UInt64, targetBP: UInt64)?

    // MARK: - AdaptiveEncoder

    public mutating func start(sequence: ChoiceSequence, targets: TargetSet, convergedOrigins: [Int: ConvergedOrigin]?) {
        self.sequence = sequence
        self.targets = []
        currentIndex = 0
        needsFirstProbe = true
        savedEntry = nil
        convergenceRecords = [:]
        pendingValidation = nil

        guard case let .spans(spans) = targets else { return }

        var i = 0
        while i < spans.count {
            let seqIdx = spans[i].range.lowerBound
            guard let v = sequence[seqIdx].value else { i += 1; continue }
            // Skip float targets — bit-pattern ordering diverges from shortlex ordering
            // near integral values (for example 999.0000000000001 has a lower bit pattern than
            // 1000.0 but a higher shortlex key). Float reduction is handled by
            // ReduceFloatEncoder and BinarySearchToSemanticSimplestEncoder.
            if v.choice.tag == .float || v.choice.tag == .double { i += 1; continue }
            let currentBP = v.choice.bitPattern64
            let isWithinRecordedRange = v.isRangeExplicit && v.choice.fits(in: v.validRange)
            let targetBP = isWithinRecordedRange
                ? v.choice.reductionTarget(in: v.validRange)
                : v.choice.semanticSimplest.bitPattern64
            guard currentBP != targetBP else { i += 1; continue }

            // Downward-only encoder: warm start narrows lo from targetBP upward.
            let validConvergedOrigin = (convergedOrigins?[seqIdx]?.direction == .downward) ? convergedOrigins?[seqIdx] : nil
            let effectiveLo = validConvergedOrigin?.bound ?? targetBP
            let isConvergedOrigined = validConvergedOrigin != nil

            self.targets.append(TargetState(
                seqIdx: seqIdx,
                validRange: v.validRange,
                isRangeExplicit: v.isRangeExplicit,
                choiceTag: v.choice.tag,
                targetBP: targetBP,
                stepper: BinarySearchStepper(lo: effectiveLo, hi: currentBP),
                isConvergedOrigined: isConvergedOrigined,
                convergedOriginBound: effectiveLo
            ))
            i += 1
        }
    }

    public mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        // Handle pending validation probe result first.
        if let validation = pendingValidation {
            pendingValidation = nil
            if lastAccepted {
                // Floor moved lower — cached bound was stale. Restart with cold stepper.
                if let saved = savedEntry {
                    sequence[validation.seqIdx] = saved
                    savedEntry = nil
                }
                targets[currentIndex] = TargetState(
                    seqIdx: targets[currentIndex].seqIdx,
                    validRange: targets[currentIndex].validRange,
                    isRangeExplicit: targets[currentIndex].isRangeExplicit,
                    choiceTag: targets[currentIndex].choiceTag,
                    targetBP: targets[currentIndex].targetBP,
                    stepper: BinarySearchStepper(lo: validation.targetBP, hi: validation.floor - 1),
                    isConvergedOrigined: false,
                    convergedOriginBound: validation.targetBP
                )
                needsFirstProbe = true
                // Fall through to main loop.
            } else {
                // Floor confirmed — restore and advance to next target.
                if let saved = savedEntry {
                    sequence[validation.seqIdx] = saved
                    savedEntry = nil
                }
                currentIndex += 1
                needsFirstProbe = true
                // Fall through to main loop.
            }
        }

        while currentIndex < targets.count {
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

            if let bp = probeValue {
                let state = targets[currentIndex]
                // In-place mutation: save entry before mutating, restore on rejection.
                // Avoids full ChoiceSequence copy per probe (COW copy deferred to caller).
                savedEntry = sequence[state.seqIdx]
                sequence[state.seqIdx] = .value(.init(
                    choice: ChoiceValue(state.choiceTag.makeConvertible(bitPattern64: bp), tag: state.choiceTag),
                    validRange: state.validRange,
                    isRangeExplicit: state.isRangeExplicit
                ))
                return sequence
            }

            // Moving to next target — restore if needed.
            if let saved = savedEntry {
                sequence[targets[currentIndex].seqIdx] = saved
                savedEntry = nil
            }
            // Record convergence for stall cache.
            let convergedTarget = targets[currentIndex]
            convergenceRecords[convergedTarget.seqIdx] = ConvergedOrigin(
                bound: convergedTarget.stepper.bestAccepted,
                direction: .downward
            )

            // Validation probe: if warm-started, verify the cached floor still holds.
            let currentBP = sequence[convergedTarget.seqIdx].value?.choice.bitPattern64 ?? convergedTarget.stepper.bestAccepted
            if convergedTarget.isConvergedOrigined,
               convergedTarget.convergedOriginBound > convergedTarget.targetBP,
               convergedTarget.convergedOriginBound > 0,
               convergedTarget.convergedOriginBound < currentBP
            {
                pendingValidation = (
                    seqIdx: convergedTarget.seqIdx,
                    floor: convergedTarget.convergedOriginBound,
                    targetBP: convergedTarget.targetBP
                )
                // Emit probe at floor - 1.
                savedEntry = sequence[convergedTarget.seqIdx]
                let probeBP = convergedTarget.convergedOriginBound - 1
                sequence[convergedTarget.seqIdx] = .value(.init(
                    choice: ChoiceValue(convergedTarget.choiceTag.makeConvertible(bitPattern64: probeBP), tag: convergedTarget.choiceTag),
                    validRange: convergedTarget.validRange,
                    isRangeExplicit: convergedTarget.isRangeExplicit
                ))
                return sequence
            }

            currentIndex += 1
            needsFirstProbe = true
        }
        return nil
    }
}
