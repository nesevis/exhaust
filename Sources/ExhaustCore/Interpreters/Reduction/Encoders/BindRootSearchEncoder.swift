//
//  BindRootSearchEncoder.swift
//  Exhaust
//
//  Created by Chris Kolbu on 14/3/2026.
//

/// Halves bind-root values toward their simplest form using PRNG fallback for bound entries.
///
/// Standard value encoders use a guided decoder with `fallbackTree`, which clamps bound entries to originals. When a bind-root value (for example, array length `n`) shrinks, the clamped bound entries may preserve incidental structure at larger sizes but break at smaller ones. This encoder avoids that by using `.guided(fallbackTree: nil)`, which lets the materializer generate fresh bound content compatible with each candidate inner value.
///
/// Uses a halving search instead of standard binary search: on rejection, the upper bound always moves to the last probe (converging toward the target) regardless of acceptance. This is correct because a rejected probe only means the PRNG seed for that candidate did not produce the right bound content — smaller values may still work with a different seed.
///
/// Only targets value entries inside a ``BindSpanIndex/BindRegion/innerRange``, the controlling values whose reduction changes bound content structure. On acceptance, returns `nil` immediately to force re-invocation with the updated sequence, since structural changes invalidate indices.
struct BindRootSearchEncoder: AdaptiveEncoder {
    let name: EncoderName = .bindRootSearch
    let phase = ReductionPhase.valueMinimization

    /// Set by the caller before ``ReductionState/runAdaptive(_:decoder:targets:structureChanged:budget:)`` invocation.
    var bindIndex: BindSpanIndex?

    func estimatedCost(sequence: ChoiceSequence, bindIndex: BindSpanIndex?) -> Int? {
        guard let bindIndex else { return nil }
        var count = 0
        for region in bindIndex.regions {
            for index in region.innerRange {
                if sequence[index].value != nil {
                    count += 1
                }
            }
        }
        return count > 0 ? count * 20 : nil
    }

    // MARK: - State

    private struct TargetState {
        let seqIdx: Int
        let validRange: ClosedRange<UInt64>?
        let isRangeExplicit: Bool
        let choiceTag: TypeTag
        var lo: UInt64
        var hi: UInt64
        var lastProbe: UInt64
    }

    private var sequence = ChoiceSequence()
    private var targets: [TargetState] = []
    private var currentIndex = 0
    private var needsFirstProbe = true
    private var savedEntry: ChoiceSequenceValue?

    // MARK: - AdaptiveEncoder

    mutating func start(sequence: ChoiceSequence, targets _: TargetSet) {
        self.sequence = sequence
        self.targets = []
        currentIndex = 0
        needsFirstProbe = true
        savedEntry = nil

        guard let bindIndex else { return }
        for region in bindIndex.regions {
            for index in region.innerRange where index < sequence.count {
                guard let value = sequence[index].value else { continue }
                let currentBitPattern = value.choice.bitPattern64
                let isWithinRecordedRange = value.isRangeExplicit && value.choice.fits(in: value.validRange)
                let targetBitPattern: UInt64 = if isWithinRecordedRange {
                    value.choice.reductionTarget(in: value.validRange)
                } else {
                    value.choice.semanticSimplest.bitPattern64
                }
                guard currentBitPattern != targetBitPattern, currentBitPattern > targetBitPattern else { continue }
                self.targets.append(TargetState(
                    seqIdx: index,
                    validRange: value.validRange,
                    isRangeExplicit: value.isRangeExplicit,
                    choiceTag: value.choice.tag,
                    lo: targetBitPattern,
                    hi: currentBitPattern,
                    lastProbe: currentBitPattern
                ))
            }
        }
    }

    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        if lastAccepted {
            // Acceptance changes sequence structure — indices are stale.
            // Return nil to force re-invocation with updated sequence.
            return nil
        }

        // Restore saved entry on rejection.
        if let saved = savedEntry {
            sequence[targets[currentIndex].seqIdx] = saved
            savedEntry = nil
        }

        while currentIndex < targets.count {
            if needsFirstProbe == false {
                // Always halve toward target, regardless of acceptance.
                // Unlike standard binary search, rejection does not move lo upward,
                // because a rejected probe just means the PRNG seed for that candidate
                // didn't produce the right bound content — smaller values may still work.
                targets[currentIndex].hi = targets[currentIndex].lastProbe
            }

            let lo = targets[currentIndex].lo
            let hi = targets[currentIndex].hi
            guard lo < hi else {
                currentIndex += 1
                needsFirstProbe = true
                continue
            }

            let midpoint = lo + (hi - lo) / 2
            targets[currentIndex].lastProbe = midpoint
            needsFirstProbe = false

            let state = targets[currentIndex]
            savedEntry = sequence[state.seqIdx]
            sequence[state.seqIdx] = .value(.init(
                choice: ChoiceValue(state.choiceTag.makeConvertible(bitPattern64: midpoint), tag: state.choiceTag),
                validRange: state.validRange,
                isRangeExplicit: state.isRangeExplicit
            ))
            return sequence
        }
        return nil
    }
}
