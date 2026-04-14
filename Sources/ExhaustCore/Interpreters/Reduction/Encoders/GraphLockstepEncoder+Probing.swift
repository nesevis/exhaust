//
//  GraphLockstepEncoder+Probing.swift
//  Exhaust
//

// MARK: - Lockstep Reduction

extension GraphLockstepEncoder {
    /// Builds suffix-window plans from each tandem group and dispatches the lockstep state.
    ///
    /// For each group of same-tag leaves, generates plans that drop progressively more leading entries — this prevents a near-target leader from blocking the whole set.
    mutating func startLockstep(scope: TandemScope, graph: ChoiceGraph) {
        var plans: [LockstepWindowPlan] = []

        for group in scope.groups {
            var indices: [Int] = []
            for nodeID in group.leafNodeIDs {
                guard let range = graph.nodes[nodeID].positionRange else { continue }
                indices.append(range.lowerBound)
            }
            indices.sort()
            guard indices.count >= 2 else { continue }

            // Build suffix windows: drop leading entries one at a time.
            var offset = 0
            while offset < indices.count - 1 {
                let windowIndices = Array(indices[offset...])
                if let plan = makeLockstepWindowPlan(windowIndices: windowIndices) {
                    plans.append(plan)
                }
                offset += 1
            }
        }

        guard plans.isEmpty == false else { return }

        mode = .active(LockstepState(
            plans: plans,
            planIndex: 0,
            probePhase: .directShot,
            stepper: MaxBinarySearchStepper(lo: 0, hi: 0),
            lastEmittedCandidate: nil,
            lastWasDirectShot: false
        ))
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
            guard case let .floating(currentFloat, _, _) = firstValue.choice else { return nil }
            let targetChoice = ChoiceValue(
                tag.makeConvertible(bitPattern64: targetBitPattern),
                tag: tag
            )
            guard case let .floating(targetFloat, _, _) = targetChoice,
                  currentFloat.isFinite,
                  targetFloat.isFinite else { return nil }
            searchUpward = targetFloat > currentFloat
            let rawDistance = abs(currentFloat - targetFloat).rounded(.down)
            guard rawDistance >= 1 else { return nil }
            distance = UInt64(rawDistance)
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
            switch state.probePhase {
            case .directShot:
                let plan = state.plans[state.planIndex]
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

                let plan = state.plans[state.planIndex]
                state.stepper = MaxBinarySearchStepper(lo: 0, hi: plan.distance)
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
                let plan = state.plans[state.planIndex]
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
    func makeLockstepCandidate(plan: LockstepWindowPlan, delta: UInt64) -> ChoiceSequence? {
        guard delta > 0 else { return nil }

        var candidate = valueState.sequence
        var firstDifferenceOrder: ShortlexOrder = .eq
        var hasDifference = false

        var entryOffset = 0
        while entryOffset < plan.originalEntries.count {
            let pair = plan.originalEntries[entryOffset]
            let i = pair.index
            let originalEntry = pair.entry
            guard let value = originalEntry.value else {
                entryOffset += 1
                continue
            }

            let newChoice: ChoiceValue
            if plan.usesFloatingSteps {
                guard case let .floating(currentFloat, _, _) = value.choice else { return nil }
                let signedDelta = plan.searchUpward ? Double(delta) : -Double(delta)
                let candidateFloat = currentFloat + signedDelta
                guard let floatChoice = Self.lockstepFloatingChoice(
                    from: candidateFloat,
                    tag: plan.tag
                ) else { return nil }
                newChoice = floatChoice
            } else {
                guard plan.searchUpward
                    ? UInt64.max - delta >= value.choice.bitPattern64
                    : value.choice.bitPattern64 >= delta
                else { return nil }

                let newBitPattern = plan.searchUpward
                    ? value.choice.bitPattern64 + delta
                    : value.choice.bitPattern64 - delta
                newChoice = ChoiceValue(
                    plan.tag.makeConvertible(bitPattern64: newBitPattern),
                    tag: plan.tag
                )
            }

            // Skip values that fall outside an explicit range.
            guard value.isRangeExplicit == false || newChoice.fits(in: value.validRange) else {
                entryOffset += 1
                continue
            }

            let newEntry = ChoiceSequenceValue.value(.init(
                choice: newChoice,
                validRange: value.validRange,
                isRangeExplicit: value.isRangeExplicit
            ))
            let order = newEntry.shortLexCompare(originalEntry)
            guard order != .eq else {
                entryOffset += 1
                continue
            }

            if hasDifference == false {
                hasDifference = true
                firstDifferenceOrder = order
            }
            candidate[i] = newEntry
            entryOffset += 1
        }

        // Only accept candidates whose first difference is a shortlex improvement.
        guard hasDifference, firstDifferenceOrder == .lt else { return nil }
        return candidate
    }

    static func lockstepFloatingChoice(from value: Double, tag: TypeTag) -> ChoiceValue? {
        switch tag {
        case .double:
            guard value.isFinite else { return nil }
            return ChoiceValue(value, tag: .double)
        case .float:
            let narrowed = Float(value)
            guard narrowed.isFinite else { return nil }
            return ChoiceValue(narrowed, tag: .float)
        case .float16:
            let encoded = Float16Emulation.encodedBitPattern(from: value)
            let reconstructed = Float16Emulation.doubleValue(fromEncoded: encoded)
            guard reconstructed.isFinite else { return nil }
            return .floating(reconstructed, encoded, .float16)
        default:
            return nil
        }
    }
}
