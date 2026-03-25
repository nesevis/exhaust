//
//  ContiguousWindowDeletionEncoder.swift
//  Exhaust
//
//  Created by Chris Kolbu on 23/3/2026.
//

/// Contiguous window deletion across structurally aligned sibling containers.
///
/// Per cohort, per slot position, uses ``FindIntegerStepper`` to find the largest
/// contiguous batch of aligned slots that can be deleted. This is the first phase
/// of aligned deletion — it dominates ``BeamSearchDeletionEncoder`` in the descriptor chain.
///
/// Extracts cohorts from sibling groups in ``start()``. Operates on the full sequence.
struct ContiguousWindowDeletionEncoder: ComposableEncoder {
    let name: EncoderName = .deleteAlignedSiblingWindows
    let phase = ReductionPhase.structuralDeletion

    // MARK: - State

    private var sequence = ChoiceSequence()
    private var cohorts: [[AlignedDeletionSlot]] = []
    private var cohortIndex = 0
    private var cohortRanges: AlignedDeletionCohortRanges?
    private var slotPosition = 0
    private var stepper = FindIntegerStepper()
    private var nonMonotonicSizes: [Int] = []
    private var nonMonotonicIndex = 0
    private var needsFirstProbe = true
    private var maxBatch = 0
    private(set) var anyAccepted = false

    // MARK: - ComposableEncoder

    func estimatedCost(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) -> Int? {
        let containerCount = ChoiceSequence.extractContainerSpans(from: sequence).count
        guard containerCount > 0 else { return nil }
        return containerCount * 10
    }

    mutating func start(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) {
        self.sequence = sequence
        cohortIndex = 0
        needsFirstProbe = true
        anyAccepted = false

        let siblingGroups = ChoiceSequence.extractSiblingGroups(from: sequence)
        cohorts = AlignedDeletionCohortBuilder.buildCohorts(
            from: sequence,
            siblingGroups: siblingGroups
        )
        .filter { $0.isEmpty == false }

        if cohorts.isEmpty == false {
            prepareCohort()
        }
    }

    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        if lastAccepted { anyAccepted = true }

        while cohortIndex < cohorts.count {
            if let candidate = nextContiguousProbe(lastAccepted: lastAccepted) {
                return candidate
            }
            // Current cohort exhausted — advance.
            cohortIndex += 1
            if cohortIndex < cohorts.count {
                prepareCohort()
            }
        }
        return nil
    }

    // MARK: - Cohort Preparation

    private mutating func prepareCohort() {
        guard cohortIndex < cohorts.count else { return }
        let slots = cohorts[cohortIndex]
        cohortRanges = AlignedDeletionCohortRanges(slots: slots)
        slotPosition = 0
        needsFirstProbe = true
        nonMonotonicSizes = []
        nonMonotonicIndex = 0
    }

    // MARK: - Contiguous Window Search

    private mutating func nextContiguousProbe(lastAccepted: Bool) -> ChoiceSequence? {
        guard let ranges = cohortRanges else { return nil }

        while slotPosition < ranges.slotCount {
            maxBatch = ranges.slotCount - slotPosition

            if needsFirstProbe {
                needsFirstProbe = false
                nonMonotonicSizes = []
                nonMonotonicIndex = 0
                let firstProbe = stepper.start()
                if let candidate = buildContiguousCandidate(
                    slotStart: slotPosition,
                    size: firstProbe,
                    ranges: ranges
                ) {
                    return candidate
                }
            }

            if nonMonotonicSizes.isEmpty == false {
                if let candidate = nextNonMonotonicProbe(
                    lastAccepted: lastAccepted,
                    ranges: ranges
                ) {
                    return candidate
                }
                slotPosition += 1
                needsFirstProbe = true
                continue
            }

            if let nextSize = stepper.advance(lastAccepted: lastAccepted) {
                if let candidate = buildContiguousCandidate(
                    slotStart: slotPosition,
                    size: nextSize,
                    ranges: ranges
                ) {
                    return candidate
                }
                continue
            }

            let bestAccepted = stepper.bestAccepted

            if bestAccepted == 0, maxBatch >= 2 {
                var sizes = [2, 3, 4, maxBatch]
                sizes = Array(Set(sizes))
                    .filter { $0 > 1 && $0 <= maxBatch }
                    .sorted()
                nonMonotonicSizes = sizes
                nonMonotonicIndex = 0
                if let candidate = nextNonMonotonicProbe(lastAccepted: false, ranges: ranges) {
                    return candidate
                }
            }

            slotPosition += max(1, bestAccepted)
            needsFirstProbe = true
        }

        return nil
    }

    private mutating func nextNonMonotonicProbe(
        lastAccepted _: Bool,
        ranges: AlignedDeletionCohortRanges
    ) -> ChoiceSequence? {
        while nonMonotonicIndex < nonMonotonicSizes.count {
            let size = nonMonotonicSizes[nonMonotonicIndex]
            nonMonotonicIndex += 1
            if let candidate = buildContiguousCandidate(
                slotStart: slotPosition,
                size: size,
                ranges: ranges
            ) {
                return candidate
            }
        }
        return nil
    }

    private func buildContiguousCandidate(
        slotStart: Int,
        size: Int,
        ranges: AlignedDeletionCohortRanges
    ) -> ChoiceSequence? {
        guard size > 0, size <= ranges.slotCount - slotStart else { return nil }
        let rangeSet = ranges.contiguousRangeSet(slotStart: slotStart, size: size)
        var candidate = sequence
        candidate.removeSubranges(rangeSet)
        guard candidate.shortLexPrecedes(sequence) else { return nil }
        return candidate
    }
}
