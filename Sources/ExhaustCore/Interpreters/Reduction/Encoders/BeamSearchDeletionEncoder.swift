//
//  BeamSearchDeletionEncoder.swift
//  Exhaust
//
//  Created by Chris Kolbu on 23/3/2026.
//

/// Non-contiguous subset deletion via beam search across aligned sibling containers.
///
/// Bitmask-encoded subsets of aligned slots, evaluated layer-by-layer with bounded beam
/// width. Falls back to uniform repair when a deletion candidate is rejected.
///
/// This is the second phase of aligned deletion — dominated by
/// ``ContiguousWindowDeletionEncoder`` in the descriptor chain. Only runs when contiguous
/// window search exhausts without finding improvements.
struct BeamSearchDeletionEncoder: ComposableEncoder {
    let name: EncoderName = .deleteAlignedSiblingSubsets
    let phase = ReductionPhase.structuralDeletion

    private let beamTuning: Interpreters.ReductionBudget.AlignedDeletionBeamSearchTuning

    init(beamTuning: Interpreters.ReductionBudget.AlignedDeletionBeamSearchTuning) {
        self.beamTuning = beamTuning
    }

    // MARK: - Types

    private struct BeamState {
        let mask: Int
        let lastAddedSlot: Int
        let deletionCount: Int
        let slotIndexSum: Int
        let heuristicScore: Int
        let rangeSet: RangeSet<Int>
    }

    // MARK: - State

    private var sequence = ChoiceSequence()
    private var cohorts: [[AlignedDeletionSlot]] = []
    private var cohortIndex = 0
    private var cohortRanges: AlignedDeletionCohortRanges?
    /// Pre-computed cohorts injected by the orchestrator to avoid duplicate extraction.
    /// Consumed once by ``start(sequence:tree:positionRange:context:)`` and reset to `nil`.
    var precomputedCohorts: [[AlignedDeletionSlot]]?

    private var beamFrontier: [BeamState] = []
    private var beamLayer = 0
    private var beamCandidateIndex = 0
    private var beamRepairPending = false
    private var layerRepairBudget = 0
    private var beamEvaluationCount = 0
    private var lastRejectedCandidate = ChoiceSequence()

    /// Detect structural stall: if sequence length hasn't decreased since last invocation,
    /// beam search is unlikely to help (contiguous search already exhausted these slots).
    private var previousSequenceLength: Int?
    private var structurallyStalled = false

    // MARK: - ComposableEncoder

    func estimatedCost(
        sequence: ChoiceSequence,
        tree _: ChoiceTree,
        positionRange _: ClosedRange<Int>,
        context _: ReductionContext
    ) -> Int? {
        let containerCount = ChoiceSequence.extractContainerSpans(from: sequence).count
        guard containerCount > 0 else { return nil }
        return containerCount * 90
    }

    mutating func start(
        sequence: ChoiceSequence,
        tree _: ChoiceTree,
        positionRange _: ClosedRange<Int>,
        context _: ReductionContext
    ) {
        structurallyStalled = (previousSequenceLength == sequence.count)
        previousSequenceLength = sequence.count
        self.sequence = sequence
        cohortIndex = 0

        if let precomputed = precomputedCohorts {
            cohorts = precomputed
            precomputedCohorts = nil
        } else {
            let siblingGroups = ChoiceSequence.extractSiblingGroups(from: sequence)
            cohorts = AlignedDeletionCohortBuilder.buildCohorts(
                from: sequence,
                siblingGroups: siblingGroups
            )
            .filter { $0.isEmpty == false }
        }

        if cohorts.isEmpty == false {
            prepareCohort()
        }
    }

    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        // Skip beam search when structurally stalled — contiguous search already exhausted.
        if structurallyStalled { return nil }

        while cohortIndex < cohorts.count {
            if let candidate = nextBeamSearchProbe(lastAccepted: lastAccepted) {
                return candidate
            }
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
        prepareBeamSearch()
    }

    private mutating func prepareBeamSearch() {
        guard let ranges = cohortRanges,
              ranges.slotCount >= 2,
              ranges.slotCount < Int.bitWidth
        else {
            beamFrontier = []
            return
        }

        beamFrontier = [BeamState(
            mask: 0,
            lastAddedSlot: -1,
            deletionCount: 0,
            slotIndexSum: 0,
            heuristicScore: 0,
            rangeSet: RangeSet<Int>()
        )]
        beamLayer = 0
        beamCandidateIndex = 0
        beamRepairPending = false
        layerRepairBudget = 3

        advanceBeamLayer()
    }

    // MARK: - Beam Search

    private mutating func advanceBeamLayer() {
        guard let ranges = cohortRanges else { return }
        beamLayer += 1
        guard beamLayer <= ranges.slotCount else {
            beamFrontier = []
            return
        }

        var expanded = [BeamState]()
        let beamWidth = beamTuning.beamWidth(for: ranges.slotCount)

        for state in beamFrontier {
            let nextSlotStart = state.lastAddedSlot + 1
            guard nextSlotStart < ranges.slotCount else { continue }

            for slotIndex in nextSlotStart ..< ranges.slotCount {
                let mask = state.mask | (1 << slotIndex)
                let slotIndexSum = state.slotIndexSum + slotIndex
                var rangeSet = state.rangeSet
                rangeSet.formUnion(ranges.slotRangeSets[slotIndex])
                expanded.append(.init(
                    mask: mask,
                    lastAddedSlot: slotIndex,
                    deletionCount: beamLayer,
                    slotIndexSum: slotIndexSum,
                    heuristicScore: beamHeuristicScore(
                        deletionCount: beamLayer,
                        slotIndexSum: slotIndexSum
                    ),
                    rangeSet: rangeSet
                ))
            }
        }

        guard expanded.isEmpty == false else {
            beamFrontier = []
            return
        }

        expanded.sort(by: beamStatePrecedes)
        if expanded.count > beamWidth {
            expanded.removeSubrange(beamWidth...)
        }
        beamFrontier = expanded
        beamCandidateIndex = 0
        beamRepairPending = false
        layerRepairBudget = 3

        beamEvaluationCount = beamTuning.evaluationsPerLayer(
            for: ranges.slotCount,
            beamWidth: beamWidth
        )
    }

    private mutating func nextBeamSearchProbe(lastAccepted: Bool) -> ChoiceSequence? {
        guard cohortRanges != nil, (cohortRanges?.slotCount ?? 0) >= 2 else { return nil }

        while beamFrontier.isEmpty == false {
            if beamRepairPending {
                beamRepairPending = false
                if layerRepairBudget > 0 {
                    layerRepairBudget -= 1
                    if let repaired = buildRepairCandidate(lastRejectedCandidate) {
                        return repaired
                    }
                }
            }

            if lastAccepted {
                return nil
            }

            while beamCandidateIndex < min(beamFrontier.count, beamEvaluationCount) {
                let state = beamFrontier[beamCandidateIndex]
                beamCandidateIndex += 1

                var candidate = sequence
                candidate.removeSubranges(state.rangeSet)
                guard candidate.shortLexPrecedes(sequence) else { continue }

                if state.deletionCount >= 2, layerRepairBudget > 0 {
                    lastRejectedCandidate = candidate
                    beamRepairPending = true
                }

                return candidate
            }

            advanceBeamLayer()
        }

        return nil
    }

    // MARK: - Repair

    private func buildRepairCandidate(_ shortened: ChoiceSequence) -> ChoiceSequence? {
        typealias ValueInfo = (
            index: Int, bp: UInt64, target: UInt64,
            distance: UInt64, upward: Bool,
            value: ChoiceSequenceValue.Value
        )
        var values = [ValueInfo]()
        for (index, entry) in shortened.enumerated() {
            guard let value = entry.value else { continue }
            let bp = value.choice.bitPattern64
            let target = value.choice.reductionTarget(in: value.validRange)
            guard bp != target else { continue }
            let upward = target > bp
            let distance = upward ? target - bp : bp - target
            values.append((index, bp, target, distance, upward, value))
        }
        guard values.isEmpty == false else { return nil }
        let maxDist = values.map(\.distance).max()!
        guard maxDist > 0 else { return nil }

        let repaired = Self.applyUniformRepair(shortened, values: values, k: 1)
        guard repaired.shortLexPrecedes(sequence) else { return nil }
        return repaired
    }

    private static func applyUniformRepair(
        _ sequence: ChoiceSequence,
        values: [(
            index: Int, bp: UInt64, target: UInt64,
            distance: UInt64, upward: Bool,
            value: ChoiceSequenceValue.Value
        )],
        k: UInt64
    ) -> ChoiceSequence {
        var result = sequence
        for value in values {
            let delta = min(value.distance, k)
            guard delta > 0 else { continue }
            let newBP = value.upward ? value.bp + delta : value.bp - delta
            let newChoice = ChoiceValue(
                value.value.choice.tag.makeConvertible(bitPattern64: newBP),
                tag: value.value.choice.tag
            )
            let reduced = ChoiceSequenceValue.Value(
                choice: newChoice,
                validRange: value.value.validRange,
                isRangeExplicit: value.value.isRangeExplicit
            )
            result[value.index] = .reduced(reduced)
        }
        return result
    }

    // MARK: - Heuristics

    private func beamHeuristicScore(deletionCount: Int, slotIndexSum: Int) -> Int {
        (deletionCount * 1024) - slotIndexSum
    }

    private func beamStatePrecedes(_ lhs: BeamState, _ rhs: BeamState) -> Bool {
        if lhs.deletionCount != rhs.deletionCount {
            return lhs.deletionCount > rhs.deletionCount
        }
        if lhs.heuristicScore != rhs.heuristicScore {
            return lhs.heuristicScore > rhs.heuristicScore
        }
        if lhs.slotIndexSum != rhs.slotIndexSum {
            return lhs.slotIndexSum < rhs.slotIndexSum
        }
        return lhs.mask < rhs.mask
    }
}
