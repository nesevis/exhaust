//
//  TandemReductionEncoder.swift
//  Exhaust
//
//  Created by Chris Kolbu on 14/3/2026.
//

/// Reduces sibling value pairs together, shifting all values in a tandem window toward their reduction target by the same delta.
///
/// For each sibling group, identifies index sets of values sharing the same ``TypeTag``, builds suffix-window plans (dropping the leading sibling on each iteration to prevent a near-target leader from blocking the set), and binary-searches for the optimal shared delta using ``BinarySearchStepper``. Before starting binary search for each plan, a direct shot at the full distance is attempted to handle non-monotonic predicates where intermediate deltas break coupling constraints but the full target delta preserves them.
///
/// - Complexity: O(*g* . *w* . log *d*), where *g* is the number of sibling groups, *w* is the number of tandem windows explored per group, and *d* is the maximum bit-pattern distance between a value and its reduction target.
public struct RedistributeByTandemReductionEncoder: AdaptiveEncoder {
    public init() {}

    public let name: EncoderName = .redistributeSiblingValuesInLockstep
    public let phase = ReductionPhase.redistribution

    public func estimatedCost(sequence: ChoiceSequence, bindIndex _: BindSpanIndex?) -> Int? {
        let g = ChoiceSequence.extractSiblingGroups(from: sequence).count
        guard g > 0 else { return nil }
        // g sibling groups × ~65: 1 direct shift probe + FindIntegerStepper search over the inter-value distance (~64 binary search steps) per group.
        return g * 65
    }

    // MARK: - Internal types

    private struct WindowPlan {
        let windowIndices: [Int]
        let tag: TypeTag
        let originalEntries: [(index: Int, entry: ChoiceSequenceValue)]
        let originalSemanticDistances: [UInt64]
        let disallowAwayMoves: Bool
        let usesFloatingSteps: Bool
        let searchUpward: Bool
        let distance: UInt64
    }

    private struct WindowCandidate {
        let sequence: ChoiceSequence
        let changedEntries: [(index: Int, entry: ChoiceSequenceValue)]
    }

    /// Tracks the position within the flattened plan list and binary search state.
    private enum ProbePhase {
        /// The next call should attempt the direct shot for the current plan.
        case directShot
        /// Awaiting the first probe from binary search.
        case binarySearchStart
        /// Binary search in progress.
        case binarySearch
    }

    // MARK: - State

    private var sequence = ChoiceSequence()
    private var plans: [WindowPlan] = []
    private var planIndex = 0
    private var probePhase = ProbePhase.directShot
    private var stepper = MaxBinarySearchStepper(lo: 0, hi: 0)
    private var lastDirectShotCandidate: WindowCandidate?
    private var lastBinaryCandidate: WindowCandidate?

    // MARK: - AdaptiveEncoder

    public mutating func start(sequence: ChoiceSequence, targets: TargetSet) {
        self.sequence = sequence
        plans = []
        planIndex = 0
        probePhase = .directShot
        lastDirectShotCandidate = nil
        lastBinaryCandidate = nil

        guard case let .siblingGroups(groups) = targets else { return }

        // Build all window plans across all sibling groups.
        // while-loop: avoiding IteratorProtocol overhead in debug builds
        var groupIdx = 0
        while groupIdx < groups.count {
            let group = groups[groupIdx]
            let indexSets = tandemIndexSets(for: group, in: sequence)
            var setIdx = 0
            while setIdx < indexSets.count {
                let indexSet = indexSets[setIdx]
                if indexSet.count >= 2 {
                    let windowPlans = buildWindowPlans(
                        for: indexSet,
                        in: sequence,
                        groupKind: group.kind
                    )
                    plans.append(contentsOf: windowPlans)
                }
                setIdx += 1
            }
            groupIdx += 1
        }
    }

    public mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        // while-loop: avoiding IteratorProtocol overhead in debug builds
        while planIndex < plans.count {
            switch probePhase {
            case .directShot:
                let plan = plans[planIndex]
                if let candidate = makeTandemCandidate(
                    plan: plan,
                    current: sequence,
                    delta: plan.distance
                ) {
                    lastDirectShotCandidate = candidate
                    probePhase = .binarySearchStart
                    return candidate.sequence
                }
                // No valid direct shot candidate; proceed to binary search.
                probePhase = .binarySearchStart
                return advanceToBinarySearch(lastAccepted: false)

            case .binarySearchStart:
                // Process direct shot feedback, then start binary search.
                if lastAccepted, let candidate = lastDirectShotCandidate {
                    applyAcceptedCandidate(candidate)
                }
                lastDirectShotCandidate = nil
                return advanceToBinarySearch(lastAccepted: lastAccepted)

            case .binarySearch:
                // Process binary search feedback.
                if lastAccepted, let candidate = lastBinaryCandidate {
                    // Don't apply yet; the stepper tracks bestAccepted.
                    _ = candidate
                }

                if let delta = stepper.advance(lastAccepted: lastAccepted) {
                    return emitBinaryProbe(delta: delta)
                }

                // Current plan's binary search converged.
                applyBestAccepted()
                planIndex += 1
                probePhase = .directShot
                lastBinaryCandidate = nil
            }
        }
        return nil
    }

    // MARK: - Binary search helpers

    /// Initializes the binary search stepper for the current plan and emits the first probe.
    private mutating func advanceToBinarySearch(lastAccepted: Bool) -> ChoiceSequence? {
        // If the direct shot was accepted, the plan is done — move to next.
        if lastAccepted, lastDirectShotCandidate != nil {
            lastDirectShotCandidate = nil
            planIndex += 1
            probePhase = .directShot
            // Recurse into the next plan via the outer while-loop.
            return nextProbe(lastAccepted: false)
        }
        lastDirectShotCandidate = nil

        let plan = plans[planIndex]
        stepper = MaxBinarySearchStepper(lo: 0, hi: plan.distance)

        guard let firstDelta = stepper.start() else {
            // Already converged (distance <= 0); move to next plan.
            planIndex += 1
            probePhase = .directShot
            return nextProbe(lastAccepted: false)
        }

        probePhase = .binarySearch
        return emitBinaryProbe(delta: firstDelta)
    }

    /// Builds and returns a probe candidate for a given binary search delta.
    private mutating func emitBinaryProbe(delta: UInt64) -> ChoiceSequence? {
        var currentDelta = delta
        let plan = plans[planIndex]
        // Loop instead of recursion: skip deltas where candidate construction fails
        // without advancing the stepper (construction failure ≠ property rejection).
        while true {
            if let candidate = makeTandemCandidate(
                plan: plan,
                current: sequence,
                delta: currentDelta
            ) {
                lastBinaryCandidate = candidate
                return candidate.sequence
            }
            // This delta produced no valid candidate. Treat as rejection and try the
            // next stepper value. The stepper converges in O(log n) steps.
            guard let nextDelta = stepper.advance(lastAccepted: false) else {
                // Stepper converged without a valid candidate.
                applyBestAccepted()
                planIndex += 1
                probePhase = .directShot
                lastBinaryCandidate = nil
                return nextProbe(lastAccepted: false)
            }
            currentDelta = nextDelta
        }
    }

    /// Applies the best accepted delta from the stepper's convergence to the base sequence.
    private mutating func applyBestAccepted() {
        let bestDelta = stepper.bestAccepted
        let plan = plans[planIndex]
        // bestAccepted is initialized to `hi` (the current value) in BinarySearchStepper,
        // so only apply if it moved below hi (meaning at least one probe was accepted).
        guard bestDelta < plan.distance else { return }
        guard bestDelta > 0 else { return }

        if let candidate = makeTandemCandidate(
            plan: plan,
            current: sequence,
            delta: bestDelta
        ) {
            applyAcceptedCandidate(candidate)
        }
    }

    /// Updates the base sequence with the entries from an accepted candidate.
    private mutating func applyAcceptedCandidate(_ candidate: WindowCandidate) {
        for (idx, entry) in candidate.changedEntries {
            sequence[idx] = entry
        }
    }

    // MARK: - Plan construction

    /// Builds suffix-window plans for an index set of same-tagged values.
    ///
    /// Each plan drops a leading prefix so that a near-target leader does not block the set.
    private func buildWindowPlans(
        for indexSet: [Int],
        in sequence: ChoiceSequence,
        groupKind: SiblingChildKind
    ) -> [WindowPlan] {
        guard indexSet.count >= 2 else { return [] }

        var plans = [WindowPlan]()
        plans.reserveCapacity(indexSet.count - 1)

        // while-loop: avoiding IteratorProtocol overhead in debug builds
        var offset = 0
        while offset < indexSet.count - 1 {
            let windowIndices = Array(indexSet[offset...])
            if let plan = makeWindowPlan(
                windowIndices: windowIndices,
                in: sequence,
                groupKind: groupKind
            ) {
                plans.append(plan)
            }
            offset += 1
        }

        return plans
    }

    /// Constructs a single window plan from window indices, computing direction, distance, and per-entry semantic distances.
    private func makeWindowPlan(
        windowIndices: [Int],
        in sequence: ChoiceSequence,
        groupKind: SiblingChildKind
    ) -> WindowPlan? {
        guard let firstValueIndex = windowIndices.first,
              let firstValue = sequence[firstValueIndex].value
        else {
            return nil
        }

        let tag = firstValue.choice.tag
        guard supportsTandemTag(tag) else { return nil }

        // All entries in the window must share the same tag.
        var idx = 1
        while idx < windowIndices.count {
            guard let value = sequence[windowIndices[idx]].value else { return nil }
            guard value.choice.tag == tag else { return nil }
            idx += 1
        }

        let currentBP = firstValue.choice.bitPattern64
        let targetBP = firstValue.choice.reductionTarget(in: firstValue.validRange)
        guard currentBP != targetBP else { return nil }

        let usesFloatingSteps = tag == .double || tag == .float
        let searchUpward: Bool
        let distance: UInt64
        if usesFloatingSteps {
            guard case let .floating(currentFloatingValue, _, _) = firstValue.choice else {
                return nil
            }
            let targetChoice = ChoiceValue(
                tag.makeConvertible(bitPattern64: targetBP),
                tag: tag
            )
            guard case let .floating(targetFloatingValue, _, _) = targetChoice,
                  currentFloatingValue.isFinite,
                  targetFloatingValue.isFinite
            else {
                return nil
            }
            searchUpward = targetFloatingValue > currentFloatingValue
            let rawDistance = abs(currentFloatingValue - targetFloatingValue).rounded(.down)
            guard rawDistance >= 1 else {
                return nil
            }
            distance = UInt64(rawDistance)
        } else {
            searchUpward = targetBP > currentBP
            distance = searchUpward
                ? targetBP - currentBP
                : currentBP - targetBP
            guard distance >= 1 else { return nil }
        }

        let originalEntries: [(index: Int, entry: ChoiceSequenceValue)] = windowIndices.map { i in
            (i, sequence[i])
        }
        var originalSemanticDistances = [UInt64]()
        originalSemanticDistances.reserveCapacity(originalEntries.count)
        for pair in originalEntries {
            guard let value = pair.entry.value else { return nil }
            originalSemanticDistances.append(semanticDistance(of: value.choice))
        }
        guard originalSemanticDistances.count == originalEntries.count else {
            return nil
        }

        return WindowPlan(
            windowIndices: windowIndices,
            tag: tag,
            originalEntries: originalEntries,
            originalSemanticDistances: originalSemanticDistances,
            disallowAwayMoves: groupKind != .bareValue,
            usesFloatingSteps: usesFloatingSteps,
            searchUpward: searchUpward,
            distance: distance
        )
    }

    // MARK: - Candidate construction

    /// Produces a candidate sequence by shifting all window values by `delta` toward their reduction target.
    ///
    /// Returns `nil` if the delta overflows, moves values out of valid range, or does not produce a shortlex improvement.
    private func makeTandemCandidate(
        plan: WindowPlan,
        current: ChoiceSequence,
        delta: UInt64
    ) -> WindowCandidate? {
        guard delta > 0 else { return nil }

        var candidate = current
        var changedEntries = [(index: Int, entry: ChoiceSequenceValue)]()
        changedEntries.reserveCapacity(plan.windowIndices.count)

        var firstDifferenceOrder: ShortlexOrder = .eq
        var hasDifference = false

        // while-loop: avoiding IteratorProtocol overhead in debug builds
        var entryOffset = 0
        while entryOffset < plan.originalEntries.count {
            let pair = plan.originalEntries[entryOffset]
            let idx = pair.index
            let originalEntry = pair.entry
            guard let value = originalEntry.value else {
                entryOffset += 1
                continue
            }

            let newChoice: ChoiceValue
            if plan.usesFloatingSteps {
                guard case let .floating(currentFloatingValue, _, _) = value.choice else {
                    return nil
                }
                let signedDelta = plan.searchUpward ? Double(delta) : -Double(delta)
                let candidateFloatingValue = currentFloatingValue + signedDelta
                guard let floatingChoice = makeFloatingChoice(from: candidateFloatingValue, tag: plan.tag) else {
                    return nil
                }
                newChoice = floatingChoice
            } else {
                // Check for overflow before applying delta.
                guard plan.searchUpward
                    ? UInt64.max - delta >= value.choice.bitPattern64
                    : value.choice.bitPattern64 >= delta
                else {
                    return nil
                }

                let newValue = plan.searchUpward
                    ? value.choice.bitPattern64 + delta
                    : value.choice.bitPattern64 - delta
                newChoice = ChoiceValue(
                    plan.tag.makeConvertible(bitPattern64: newValue),
                    tag: plan.tag
                )
            }

            // Skip values that fall outside an explicit range.
            guard value.isRangeExplicit == false || newChoice.fits(in: value.validRange) else {
                entryOffset += 1
                continue
            }

            // Reject any entry that moves further from its reduction target.
            if plan.disallowAwayMoves {
                let beforeDistance = plan.originalSemanticDistances[entryOffset]
                let afterDistance = semanticDistance(of: newChoice)
                if afterDistance > beforeDistance {
                    return nil
                }
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
            candidate[idx] = newEntry
            changedEntries.append((idx, newEntry))
            entryOffset += 1
        }

        // Only accept candidates whose first difference is a shortlex improvement.
        guard hasDifference, firstDifferenceOrder == .lt else {
            return nil
        }

        return WindowCandidate(sequence: candidate, changedEntries: changedEntries)
    }

    // MARK: - Index set construction

    /// Groups values within a sibling group into index sets of same-typed values suitable for tandem reduction.
    private func tandemIndexSets(
        for group: SiblingGroup,
        in sequence: ChoiceSequence
    ) -> [[Int]] {
        if let valueRanges = group.valueRanges, valueRanges.count >= 2 {
            let indices = valueRanges.map(\.lowerBound)
            var byTag = [TypeTag: [Int]]()
            for idx in indices {
                guard let value = sequence[idx].value else { continue }
                byTag[value.choice.tag, default: []].append(idx)
            }
            let grouped = byTag.values
                .filter { $0.count >= 2 }
                .sorted(by: { ($0.first ?? 0) < ($1.first ?? 0) })
            if grouped.isEmpty == false {
                return grouped
            }
            return [indices]
        }

        // For container sibling groups, align values by internal offset across siblings.
        let perSiblingValueIndices = group.ranges.map { range in
            valueIndices(in: sequence, within: range)
        }
        guard perSiblingValueIndices.count >= 2 else { return [] }
        let sharedValueCount = perSiblingValueIndices.map(\.count).min() ?? 0
        guard sharedValueCount > 0 else { return [] }

        var alignedSets = [[Int]]()
        alignedSets.reserveCapacity(sharedValueCount)
        var valueOffset = 0
        while valueOffset < sharedValueCount {
            let aligned = perSiblingValueIndices.map { $0[valueOffset] }
            if aligned.count >= 2 {
                alignedSets.append(aligned)
            }
            valueOffset += 1
        }

        // Tag-based grouping: break each aligned set into per-tag subsets so same-type values
        // can be reduced in tandem even when separated by unrelated draws.
        let alignedAsSetsBeforeTagGrouping = Set(alignedSets.map { Set($0) })
        var tagGroupedSets = [[Int]]()
        for aligned in alignedSets {
            var byTag = [TypeTag: [Int]]()
            for idx in aligned {
                guard let value = sequence[idx].value else { continue }
                byTag[value.choice.tag, default: []].append(idx)
            }
            for (_, indices) in byTag where indices.count >= 2 {
                if alignedAsSetsBeforeTagGrouping.contains(Set(indices)) == false {
                    tagGroupedSets.append(indices)
                }
            }
        }
        alignedSets.append(contentsOf: tagGroupedSets)

        // Value-matched grouping: find entries with the same (tag, bitPattern) across
        // all siblings and reduce them in lockstep.
        let alignedAsSets = Set(alignedSets.map { Set($0) })
        var byTagAndValue = [TypeTag: [UInt64: [Int]]]()
        for indices in perSiblingValueIndices {
            for idx in indices {
                guard let value = sequence[idx].value else { continue }
                byTagAndValue[value.choice.tag, default: [:]][value.choice.bitPattern64, default: []].append(idx)
            }
        }
        for (_, byBitPattern) in byTagAndValue {
            for (_, indices) in byBitPattern where indices.count >= 2 {
                if alignedAsSets.contains(Set(indices)) == false {
                    alignedSets.append(indices)
                }
            }
        }

        return alignedSets
    }

    /// Returns the indices of value entries within a range of the sequence.
    private func valueIndices(
        in sequence: ChoiceSequence,
        within range: ClosedRange<Int>
    ) -> [Int] {
        var indices = [Int]()
        indices.reserveCapacity(range.count)
        for idx in range where sequence[idx].value != nil {
            indices.append(idx)
        }
        return indices
    }

    // MARK: - Utilities

    /// Returns whether tandem reduction supports the given type tag.
    private func supportsTandemTag(_ tag: TypeTag) -> Bool {
        switch tag {
        case .int, .int64, .int32, .int16, .int8, .uint, .uint64, .uint32, .uint16, .uint8, .double, .float, .date, .bits:
            true
        }
    }

    /// Computes the shortlex distance between a value and its semantic simplest form.
    private func semanticDistance(of value: ChoiceValue) -> UInt64 {
        let simplest = value.semanticSimplest
        let lhs = value.shortlexKey
        let rhs = simplest.shortlexKey
        return lhs >= rhs ? (lhs - rhs) : (rhs - lhs)
    }

    /// Creates a floating-point ``ChoiceValue`` from a `Double`, narrowing to `Float` if the tag requires it.
    private func makeFloatingChoice(from value: Double, tag: TypeTag) -> ChoiceValue? {
        switch tag {
        case .double:
            guard value.isFinite else { return nil }
            return ChoiceValue(value, tag: .double)
        case .float:
            let narrowed = Float(value)
            guard narrowed.isFinite else { return nil }
            return ChoiceValue(narrowed, tag: .float)
        default:
            return nil
        }
    }
}
