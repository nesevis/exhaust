//
//  GraphLockstepEncoder+Probing.swift
//  Exhaust
//

// MARK: - Lockstep Reduction

extension GraphLockstepEncoder {
    /// Builds numeric windows, complete equal-character proposals, then character windows.
    ///
    /// For each group of same-tag leaves, generates plans that drop progressively more leading entries — this prevents a near-target leader from blocking the whole set.
    mutating func startLockstep(scope: TandemScope, graph: ChoiceGraph) {
        var plans: [LockstepPlan] = []
        var characterWindows: [LockstepPlan] = []

        for group in scope.groups {
            var indices: [Int] = []
            for leaf in group.leaves {
                guard let range = graph.nodes[leaf.nodeID].positionRange else { continue }
                indices.append(range.lowerBound)
            }
            indices.sort()
            guard indices.count >= 2 else { continue }

            // Build suffix windows: drop leading entries one at a time, capped to avoid O(n) plan construction on large groups.
            let maxWindows = min(indices.count - 1, SchedulerTuning.maxPairLookahead)
            var offset = 0
            while offset < maxWindows {
                let windowIndices = Array(indices[offset...])
                if let plan = makeLockstepWindowPlan(windowIndices: windowIndices) {
                    if group.typeTag == .character {
                        characterWindows.append(.shift(plan))
                    } else {
                        plans.append(.shift(plan))
                    }
                }
                offset += 1
            }
        }

        // Numeric searches precede character proposals. Try complete equal-character
        // groups before the suffix windows, which can change only some occurrences.
        plans.append(contentsOf: characterPlans(graph: graph))
        plans.append(contentsOf: characterWindows)

        guard plans.isEmpty == false else { return }

        mode = .active(LockstepState(
            plans: plans,
            planIndex: 0,
            characterCandidateIndex: 0,
            probePhase: .directShot,
            stepper: BinarySearchStepper(lo: 0, hi: 0, direction: .findLargest),
            lastEmittedCandidate: nil,
            lastWasDirectShot: false
        ))
    }

    /// Character indices are comparable only within the same scalar map and range.
    private struct CharacterGroupKey: Hashable {
        let domain: CharacterDomain
        let range: ClosedRange<UInt64>?
        let value: UInt64
    }

    private func characterPlans(graph: ChoiceGraph) -> [LockstepPlan] {
        var groups: [CharacterGroupKey: [Int]] = [:]
        for nodeID in graph.characterLeafNodes {
            let node = graph.nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind,
                  let domain = metadata.characterDomain,
                  let index = node.positionRange?.lowerBound,
                  valueState.leafLookup[index] != nil,
                  let value = valueState.sequence[index].value else { continue }
            let key = CharacterGroupKey(domain: domain, range: value.validRange, value: value.choice.bitPattern64)
            groups[key, default: []].append(index)
        }

        return groups.values.filter { $0.count >= 2 }.map { $0.sorted() }.sorted {
            $0[0] < $1[0]
        }.compactMap { indices in
            guard let first = valueState.sequence[indices[0]].value,
                  let nodeID = valueState.leafLookup[indices[0]]?.nodeID,
                  case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { return nil }
            let current = first.choice.bitPattern64
            var candidates = [first.choice.reductionTarget(in: first.validRange)]
            if let simplifications = metadata.characterSimplifications {
                candidates.append(contentsOf: simplifications.simplerIndices(than: current))
            }
            var seen: Set<UInt64> = []
            candidates = candidates.filter { $0 < current && seen.insert($0).inserted }
            guard candidates.isEmpty == false else { return nil }
            return .characters(indices: indices, candidates: candidates)
        }
    }

    /// Constructs a window plan from indices, computing direction and distance from the leader.
    ///
    /// Returns `nil` when any window index has become stale relative to the current sequence — a defensive guard against structural refreshes that happened between scope construction and plan building.
    func makeLockstepWindowPlan(windowIndices: [Int]) -> LockstepWindowPlan? {
        guard let firstIndex = windowIndices.first,
              firstIndex < valueState.sequence.count,
              let firstValue = valueState.sequence[firstIndex].value else { return nil }

        let tag = firstValue.choice.tag

        // All entries must share the same tag.
        var i = 1
        while i < windowIndices.count {
            let windowIndex = windowIndices[i]
            guard windowIndex < valueState.sequence.count,
                  let value = valueState.sequence[windowIndex].value,
                  value.choice.tag == tag else { return nil }
            i += 1
        }

        let currentBitPattern = firstValue.choice.bitPattern64
        let targetBitPattern = firstValue.choice.reductionTarget(in: firstValue.validRange)
        guard currentBitPattern != targetBitPattern else { return nil }

        let usesFloatingSteps = tag.isFloatingPoint
        let searchUpward: Bool
        let distance: UInt64
        if usesFloatingSteps {
            let currentFloat = firstValue.choice.decodedDoubleValue
            let targetChoice = ChoiceValue(
                tag.makeConvertible(bitPattern64: targetBitPattern),
                tag: tag
            )
            let targetFloat = targetChoice.decodedDoubleValue
            guard currentFloat.isFinite,
                  targetFloat.isFinite else { return nil }
            searchUpward = targetFloat > currentFloat
            let rawDistance = abs(currentFloat - targetFloat).rounded(.down)
            guard rawDistance >= 1 else { return nil }
            // The operands are finite but their difference can exceed UInt64.max, or overflow to infinity outright. Clamp instead of trapping: the distance only seeds probe deltas, and the binary search narrows from wherever the cap lands.
            distance = rawDistance < 0x1p64 ? UInt64(rawDistance) : UInt64.max
        } else {
            searchUpward = targetBitPattern > currentBitPattern
            distance = searchUpward ? targetBitPattern - currentBitPattern : currentBitPattern - targetBitPattern
            guard distance >= 1 else { return nil }
        }

        let originalEntries: [(index: Int, entry: ChoiceSequenceValue)] = windowIndices.map { i in
            (i, valueState.sequence[i])
        }

        return LockstepWindowPlan(
            windowIndices: windowIndices,
            tag: tag,
            originalEntries: originalEntries,
            searchUpward: searchUpward,
            distance: distance,
            usesFloatingSteps: usesFloatingSteps
        )
    }

    mutating func nextLockstepProbe(
        state: inout LockstepState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        while state.planIndex < state.plans.count {
            if case let .characters(indices, candidates) = state.plans[state.planIndex] {
                while state.characterCandidateIndex < candidates.count {
                    let value = candidates[state.characterCandidateIndex]
                    state.characterCandidateIndex += 1
                    // Compare against the accepted baseline, never restore an earlier value.
                    guard indices.allSatisfy({ index in
                        guard let current = valueState.sequence[index].value else { return false }
                        return value < current.choice.bitPattern64 && (current.validRange?.contains(value) ?? true)
                    }) else { continue }
                    var candidate = valueState.sequence
                    for index in indices {
                        candidate[index] = candidate[index].withBitPattern(value)
                    }
                    return candidate
                }
                state.planIndex += 1
                state.characterCandidateIndex = 0
                continue
            }
            guard case let .shift(plan) = state.plans[state.planIndex] else { continue }
            switch state.probePhase {
                case .directShot:
                    if let candidate = makeLockstepCandidate(plan: plan, delta: plan.distance) {
                        state.lastEmittedCandidate = candidate
                        state.lastWasDirectShot = true
                        state.probePhase = .binarySearchStart
                        return candidate
                    }
                    // No valid direct shot — fall through to binary search.
                    state.probePhase = .binarySearchStart
                    continue

                case .binarySearchStart:
                    // If the direct shot was accepted, the plan is done.
                    if lastAccepted, state.lastWasDirectShot {
                        state.lastWasDirectShot = false
                        state.planIndex += 1
                        state.probePhase = .directShot
                        continue
                    }
                    state.lastWasDirectShot = false

                    state.stepper = BinarySearchStepper(lo: 0, hi: plan.distance, direction: .findLargest)
                    guard let firstDelta = state.stepper.start() else {
                        state.planIndex += 1
                        state.probePhase = .directShot
                        continue
                    }
                    state.probePhase = .binarySearch
                    if let candidate = makeLockstepCandidate(plan: plan, delta: firstDelta) {
                        state.lastEmittedCandidate = candidate
                        return candidate
                    }
                    // First probe didn't yield a candidate — advance stepper.
                    continue

                case .binarySearch:
                    guard let nextDelta = state.stepper.advance(lastAccepted: lastAccepted) else {
                        // Converged — move to next plan.
                        state.planIndex += 1
                        state.probePhase = .directShot
                        continue
                    }
                    if let candidate = makeLockstepCandidate(plan: plan, delta: nextDelta) {
                        state.lastEmittedCandidate = candidate
                        return candidate
                    }
                    continue
            }
        }
        return nil
    }

    /// Produces a candidate sequence by shifting all window values toward their reduction target by `delta`.
    ///
    /// Only candidates whose first difference is a shortlex improvement are returned.
    func makeLockstepCandidate(plan: LockstepWindowPlan, delta: UInt64) -> ChoiceSequence? {
        guard let (candidate, firstDifferenceOrder) = valueState.sequence.shiftingGroup(
            entries: plan.originalEntries,
            tag: plan.tag,
            shiftUpward: plan.searchUpward,
            delta: delta,
            usesFloatingSteps: plan.usesFloatingSteps,
            policy: .skipUnmovable
        ) else {
            return nil
        }
        guard firstDifferenceOrder == .lt else { return nil }
        if plan.tag == .character {
            // Window deltas remain anchored to their original entries. A preceding
            // uniform simplification may already have improved the accepted baseline.
            for index in plan.windowIndices {
                let order = candidate[index].shortLexCompare(valueState.sequence[index])
                if order != .eq { return order == .lt ? candidate : nil }
            }
            return nil
        }
        return candidate
    }
}
