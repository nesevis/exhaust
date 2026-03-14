//
//  DeleteAlignedWindowsEncoder.swift
//  Exhaust
//
//  Created by Chris Kolbu on 14/3/2026.
//

/// Coordinated deletion across structurally aligned sibling containers.
///
/// Two phases:
/// 1. **Contiguous window search** — per cohort, per slot position, uses ``FindIntegerStepper``
///    to find the largest contiguous batch of aligned slots that can be deleted.
/// 2. **Beam search subset deletion** — bitmask-encoded non-contiguous subsets, evaluated
///    layer-by-layer with bounded beam width.
struct DeleteAlignedWindowsEncoder: AdaptiveEncoder {
    init(beamTuning: Interpreters.TCRConfiguration.AlignedDeletionBeamSearchTuning) {
        self.beamTuning = beamTuning
    }

    let name = "deleteAlignedWindows"
    let phase = ReductionPhase.structuralDeletion

    var grade: ReductionGrade {
        ReductionGrade(approximation: .exact, maxMaterializations: 0)
    }

    // MARK: - Configuration

    private let beamTuning: Interpreters.TCRConfiguration.AlignedDeletionBeamSearchTuning

    // MARK: - Types

    private enum SearchPhase {
        case contiguous
        case beamSearch
    }

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
    private var searchPhase = SearchPhase.contiguous

    // Phase 1 state
    private var cohortRanges: AlignedDeletionCohortRanges?
    private var slotPosition = 0
    private var stepper = FindIntegerStepper()
    private var nonMonotonicSizes: [Int] = []
    private var nonMonotonicIndex = 0
    private var phaseOneFoundAnything = false
    private var needsFirstProbe = true
    private var maxBatch = 0

    // Phase 2 state
    private var beamFrontier: [BeamState] = []
    private var beamLayer = 0
    private var beamCandidateIndex = 0
    private var beamRepairPending = false
    private var layerRepairBudget = 0
    private var beamEvaluationCount = 0
    private var lastRejectedCandidate = ChoiceSequence()

    // MARK: - AdaptiveEncoder

    mutating func start(sequence: ChoiceSequence, targets: TargetSet) {
        self.sequence = sequence
        self.cohortIndex = 0
        self.searchPhase = .contiguous
        self.needsFirstProbe = true

        let siblingGroups = ChoiceSequence.extractSiblingGroups(from: sequence)
        self.cohorts = AlignedDeletionCohortBuilder.buildCohorts(from: sequence, siblingGroups: siblingGroups)
            .filter { $0.isEmpty == false }

        if cohorts.isEmpty == false {
            prepareCohort()
        }
    }

    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        while cohortIndex < cohorts.count {
            switch searchPhase {
            case .contiguous:
                if let candidate = nextContiguousProbe(lastAccepted: lastAccepted) {
                    return candidate
                }
            case .beamSearch:
                if let candidate = nextBeamSearchProbe(lastAccepted: lastAccepted) {
                    return candidate
                }
            }

            // Current phase/cohort exhausted — advance.
            if advanceCohortOrPhase(lastAccepted: lastAccepted) == false {
                return nil
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
        phaseOneFoundAnything = false
        searchPhase = .contiguous
        needsFirstProbe = true
        nonMonotonicSizes = []
        nonMonotonicIndex = 0
    }

    // MARK: - Phase 1: Contiguous Window Search

    private mutating func nextContiguousProbe(lastAccepted: Bool) -> ChoiceSequence? {
        guard let ranges = cohortRanges else { return nil }

        while slotPosition < ranges.slotCount {
            maxBatch = ranges.slotCount - slotPosition

            if needsFirstProbe {
                needsFirstProbe = false
                nonMonotonicSizes = []
                nonMonotonicIndex = 0
                let firstProbe = stepper.start()
                if let candidate = buildContiguousCandidate(slotStart: slotPosition, size: firstProbe, ranges: ranges) {
                    return candidate
                }
                // Size 1 not buildable — skip to non-monotonic or next position.
            }

            // Check if we're in non-monotonic fallback.
            if nonMonotonicSizes.isEmpty == false {
                if let candidate = nextNonMonotonicProbe(lastAccepted: lastAccepted, ranges: ranges) {
                    return candidate
                }
                // Non-monotonic exhausted — move to next slot position.
                slotPosition += 1
                needsFirstProbe = true
                continue
            }

            if let nextSize = stepper.advance(lastAccepted: lastAccepted) {
                if lastAccepted {
                    phaseOneFoundAnything = true
                }
                if let candidate = buildContiguousCandidate(slotStart: slotPosition, size: nextSize, ranges: ranges) {
                    return candidate
                }
                continue
            }

            // Stepper converged.
            if lastAccepted {
                phaseOneFoundAnything = true
            }
            let bestAccepted = stepper.bestAccepted

            if bestAccepted == 0, maxBatch >= 2 {
                // Non-monotonic fallback.
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

    private mutating func nextNonMonotonicProbe(lastAccepted: Bool, ranges: AlignedDeletionCohortRanges) -> ChoiceSequence? {
        if lastAccepted {
            phaseOneFoundAnything = true
        }
        while nonMonotonicIndex < nonMonotonicSizes.count {
            let size = nonMonotonicSizes[nonMonotonicIndex]
            nonMonotonicIndex += 1
            if let candidate = buildContiguousCandidate(slotStart: slotPosition, size: size, ranges: ranges) {
                return candidate
            }
        }
        return nil
    }

    private func buildContiguousCandidate(slotStart: Int, size: Int, ranges: AlignedDeletionCohortRanges) -> ChoiceSequence? {
        guard size > 0, size <= ranges.slotCount - slotStart else { return nil }
        let rangeSet = ranges.contiguousRangeSet(slotStart: slotStart, size: size)
        var candidate = sequence
        candidate.removeSubranges(rangeSet)
        guard candidate.shortLexPrecedes(sequence) else { return nil }
        return candidate
    }

    // MARK: - Phase 2: Beam Search Subset Deletion

    private mutating func prepareBeamSearch() {
        guard let ranges = cohortRanges, ranges.slotCount >= 2, ranges.slotCount < Int.bitWidth else {
            // Can't do beam search — advance to next cohort.
            return
        }

        beamFrontier = [BeamState(
            mask: 0,
            lastAddedSlot: -1,
            deletionCount: 0,
            slotIndexSum: 0,
            heuristicScore: 0,
            rangeSet: RangeSet<Int>(),
        )]
        beamLayer = 0
        beamCandidateIndex = 0
        beamRepairPending = false
        layerRepairBudget = 3

        advanceBeamLayer()
    }

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
                    heuristicScore: beamHeuristicScore(deletionCount: beamLayer, slotIndexSum: slotIndexSum),
                    rangeSet: rangeSet,
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
            beamWidth: beamWidth,
        )
    }

    private mutating func nextBeamSearchProbe(lastAccepted: Bool) -> ChoiceSequence? {
        guard let ranges = cohortRanges, ranges.slotCount >= 2 else { return nil }

        while beamFrontier.isEmpty == false {
            // Handle repair pending from last rejection.
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
                // Any acceptance in beam search — done with this cohort.
                return nil
            }

            while beamCandidateIndex < min(beamFrontier.count, beamEvaluationCount) {
                let state = beamFrontier[beamCandidateIndex]
                beamCandidateIndex += 1

                var candidate = sequence
                candidate.removeSubranges(state.rangeSet)
                guard candidate.shortLexPrecedes(sequence) else { continue }

                // Set up repair pending for rejection case.
                if state.deletionCount >= 2, layerRepairBudget > 0 {
                    lastRejectedCandidate = candidate
                    beamRepairPending = true
                }

                return candidate
            }

            // Layer exhausted — advance to next layer.
            advanceBeamLayer()
        }

        return nil
    }

    private func buildRepairCandidate(_ shortened: ChoiceSequence) -> ChoiceSequence? {
        typealias ValueInfo = (index: Int, bp: UInt64, target: UInt64, distance: UInt64, upward: Bool, value: ChoiceSequenceValue.Value)
        var values = [ValueInfo]()
        for (i, entry) in shortened.enumerated() {
            guard let v = entry.value else { continue }
            let bp = v.choice.bitPattern64
            let target = v.choice.reductionTarget(in: v.validRange)
            guard bp != target else { continue }
            let upward = target > bp
            let distance = upward ? target - bp : bp - target
            values.append((i, bp, target, distance, upward, v))
        }
        guard values.isEmpty == false else { return nil }
        let maxDist = values.map(\.distance).max()!
        guard maxDist > 0 else { return nil }

        // Apply uniform repair with k=1 as a quick repair probe.
        let repaired = ReducerStrategies.applyUniformRepair(shortened, values: values, k: 1)
        guard repaired.shortLexPrecedes(sequence) else { return nil }
        return repaired
    }

    // MARK: - Cohort/Phase Advancement

    private mutating func advanceCohortOrPhase(lastAccepted: Bool) -> Bool {
        if lastAccepted {
            phaseOneFoundAnything = true
        }

        switch searchPhase {
        case .contiguous:
            if phaseOneFoundAnything {
                // Contiguous found something — move to next cohort still in contiguous phase.
                cohortIndex += 1
                if cohortIndex < cohorts.count {
                    prepareCohort()
                    return true
                }
                return false
            }
            // Contiguous found nothing — try beam search for this cohort.
            searchPhase = .beamSearch
            prepareBeamSearch()
            if beamFrontier.isEmpty {
                // Can't do beam search — next cohort.
                cohortIndex += 1
                if cohortIndex < cohorts.count {
                    prepareCohort()
                    return true
                }
                return false
            }
            return true

        case .beamSearch:
            // Beam search exhausted — next cohort.
            cohortIndex += 1
            if cohortIndex < cohorts.count {
                prepareCohort()
                return true
            }
            return false
        }
    }

    // MARK: - Beam Heuristics

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
