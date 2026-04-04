//
//  GraphTandemReductionEncoder.swift
//  Exhaust
//

// MARK: - Graph Tandem Reduction Encoder

/// Reduces groups of same-typed leaf values in lockstep, shifting all values by the same delta toward their reduction target.
///
/// Uses type-compatibility edges from the ``ChoiceGraph`` to identify groups of same-typed leaves. For each group, builds suffix-window plans (dropping the leading sibling on each iteration to prevent a near-target leader from blocking the set) and binary-searches for the optimal shared delta using ``MaxBinarySearchStepper``. Before binary search, a direct shot at the full distance is attempted for non-monotonic predicates.
///
/// This is the graph-based counterpart of ``RedistributeByTandemReductionEncoder``. The graph provides type-compatible leaf groupings directly via layer 4 edges.
///
/// - SeeAlso: ``RedistributeByTandemReductionEncoder``, ``GraphRedistributionEncoder``
public struct GraphTandemReductionEncoder: GraphEncoder {
    public let name: EncoderName = .graphTandem

    // MARK: - State

    private var sequence = ChoiceSequence()
    private var plans: [WindowPlan] = []
    private var planIndex = 0
    private var probePhase = ProbePhase.directShot
    private var stepper = MaxBinarySearchStepper(lo: 0, hi: 0)
    private var lastDirectShotCandidate: WindowCandidate?
    private var lastBinaryCandidate: WindowCandidate?

    private struct WindowPlan {
        let windowIndices: [Int]
        let tag: TypeTag
        let originalEntries: [(index: Int, entry: ChoiceSequenceValue)]
        let originalSemanticDistances: [UInt64]
        let usesFloatingSteps: Bool
        let searchUpward: Bool
        let distance: UInt64
    }

    private struct WindowCandidate {
        let sequence: ChoiceSequence
        let changedEntries: [(index: Int, entry: ChoiceSequenceValue)]
    }

    private enum ProbePhase {
        case directShot
        case binarySearchStart
        case binarySearch
    }

    // MARK: - GraphEncoder

    public mutating func start(
        graph: ChoiceGraph,
        sequence: ChoiceSequence,
        tree _: ChoiceTree
    ) {
        self.sequence = sequence
        plans = []
        planIndex = 0
        probePhase = .directShot
        lastDirectShotCandidate = nil
        lastBinaryCandidate = nil

        // Group leaves by TypeTag using type-compatibility edges.
        var leafGroupsByTag: [TypeTag: [Int]] = [:]
        for nodeID in graph.leafNodes {
            let node = graph.nodes[nodeID]
            guard case let .chooseBits(metadata) = node.kind,
                  let positionRange = node.positionRange
            else { continue }
            leafGroupsByTag[metadata.typeTag, default: []].append(positionRange.lowerBound)
        }

        // Build suffix-window plans for each group with at least two members.
        for (_, indices) in leafGroupsByTag {
            guard indices.count >= 2 else { continue }
            let sorted = indices.sorted()
            let windowPlans = buildWindowPlans(for: sorted, in: sequence)
            plans.append(contentsOf: windowPlans)
        }
    }

    public mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
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
                probePhase = .binarySearchStart
                return advanceToBinarySearch(lastAccepted: false)

            case .binarySearchStart:
                if lastAccepted, let candidate = lastDirectShotCandidate {
                    applyAcceptedCandidate(candidate)
                }
                lastDirectShotCandidate = nil
                return advanceToBinarySearch(lastAccepted: lastAccepted)

            case .binarySearch:
                if lastAccepted, let candidate = lastBinaryCandidate {
                    _ = candidate
                }

                if let delta = stepper.advance(lastAccepted: lastAccepted) {
                    return emitBinaryProbe(delta: delta)
                }

                applyBestAccepted()
                planIndex += 1
                probePhase = .directShot
                lastBinaryCandidate = nil
            }
        }
        return nil
    }

    // MARK: - Binary Search

    private mutating func advanceToBinarySearch(lastAccepted: Bool) -> ChoiceSequence? {
        if lastAccepted, lastDirectShotCandidate != nil {
            lastDirectShotCandidate = nil
            planIndex += 1
            probePhase = .directShot
            return nextProbe(lastAccepted: false)
        }
        lastDirectShotCandidate = nil

        let plan = plans[planIndex]
        stepper = MaxBinarySearchStepper(lo: 0, hi: plan.distance)

        guard let firstDelta = stepper.start() else {
            planIndex += 1
            probePhase = .directShot
            return nextProbe(lastAccepted: false)
        }

        probePhase = .binarySearch
        return emitBinaryProbe(delta: firstDelta)
    }

    private mutating func emitBinaryProbe(delta: UInt64) -> ChoiceSequence? {
        var currentDelta = delta
        let plan = plans[planIndex]
        while true {
            if let candidate = makeTandemCandidate(
                plan: plan,
                current: sequence,
                delta: currentDelta
            ) {
                lastBinaryCandidate = candidate
                return candidate.sequence
            }
            guard let nextDelta = stepper.advance(lastAccepted: false) else {
                applyBestAccepted()
                planIndex += 1
                probePhase = .directShot
                lastBinaryCandidate = nil
                return nextProbe(lastAccepted: false)
            }
            currentDelta = nextDelta
        }
    }

    private mutating func applyBestAccepted() {
        let bestDelta = stepper.bestAccepted
        let plan = plans[planIndex]
        guard bestDelta < plan.distance, bestDelta > 0 else { return }

        if let candidate = makeTandemCandidate(
            plan: plan,
            current: sequence,
            delta: bestDelta
        ) {
            applyAcceptedCandidate(candidate)
        }
    }

    private mutating func applyAcceptedCandidate(_ candidate: WindowCandidate) {
        for (index, entry) in candidate.changedEntries {
            sequence[index] = entry
        }
    }

    // MARK: - Plan Construction

    /// Builds suffix-window plans: each plan drops one leading element to prevent near-target leaders from blocking the set.
    private func buildWindowPlans(
        for indices: [Int],
        in sequence: ChoiceSequence
    ) -> [WindowPlan] {
        guard indices.count >= 2 else { return [] }
        var plans = [WindowPlan]()
        plans.reserveCapacity(indices.count - 1)

        var offset = 0
        while offset < indices.count - 1 {
            let windowIndices = Array(indices[offset...])
            if let plan = makeWindowPlan(windowIndices: windowIndices, in: sequence) {
                plans.append(plan)
            }
            offset += 1
        }
        return plans
    }

    private func makeWindowPlan(
        windowIndices: [Int],
        in sequence: ChoiceSequence
    ) -> WindowPlan? {
        guard let firstIndex = windowIndices.first,
              let firstValue = sequence[firstIndex].value
        else {
            return nil
        }

        let tag = firstValue.choice.tag

        // All entries must share the same tag.
        var index = 1
        while index < windowIndices.count {
            guard let value = sequence[windowIndices[index]].value else { return nil }
            guard value.choice.tag == tag else { return nil }
            index += 1
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
                  targetFloat.isFinite
            else {
                return nil
            }
            searchUpward = targetFloat > currentFloat
            let rawDistance = abs(currentFloat - targetFloat).rounded(.down)
            guard rawDistance >= 1 else { return nil }
            distance = UInt64(rawDistance)
        } else {
            searchUpward = targetBitPattern > currentBitPattern
            distance = searchUpward
                ? targetBitPattern - currentBitPattern
                : currentBitPattern - targetBitPattern
            guard distance >= 1 else { return nil }
        }

        let originalEntries: [(index: Int, entry: ChoiceSequenceValue)] = windowIndices.map { idx in
            (idx, sequence[idx])
        }
        var originalSemanticDistances = [UInt64]()
        originalSemanticDistances.reserveCapacity(originalEntries.count)
        for pair in originalEntries {
            guard let value = pair.entry.value else { return nil }
            originalSemanticDistances.append(semanticDistance(of: value.choice))
        }

        return WindowPlan(
            windowIndices: windowIndices,
            tag: tag,
            originalEntries: originalEntries,
            originalSemanticDistances: originalSemanticDistances,
            usesFloatingSteps: usesFloatingSteps,
            searchUpward: searchUpward,
            distance: distance
        )
    }

    // MARK: - Candidate Construction

    /// Produces a candidate sequence by shifting all window values by `delta` toward their reduction target.
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

        var entryOffset = 0
        while entryOffset < plan.originalEntries.count {
            let pair = plan.originalEntries[entryOffset]
            let index = pair.index
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
                guard let floatingChoice = makeFloatingChoice(
                    from: candidateFloat,
                    tag: plan.tag
                ) else {
                    return nil
                }
                newChoice = floatingChoice
            } else {
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

            guard value.isRangeExplicit == false || newChoice.fits(in: value.validRange) else {
                entryOffset += 1
                continue
            }

            // Reject entries that move further from their target.
            let beforeDistance = plan.originalSemanticDistances[entryOffset]
            let afterDistance = semanticDistance(of: newChoice)
            if afterDistance > beforeDistance {
                return nil
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
            candidate[index] = newEntry
            changedEntries.append((index, newEntry))
            entryOffset += 1
        }

        guard hasDifference, firstDifferenceOrder == .lt else {
            return nil
        }

        return WindowCandidate(sequence: candidate, changedEntries: changedEntries)
    }

    // MARK: - Utilities

    private func semanticDistance(of value: ChoiceValue) -> UInt64 {
        let simplest = value.semanticSimplest
        let lhs = value.shortlexKey
        let rhs = simplest.shortlexKey
        return lhs >= rhs ? (lhs - rhs) : (rhs - lhs)
    }

    private func makeFloatingChoice(from value: Double, tag: TypeTag) -> ChoiceValue? {
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
