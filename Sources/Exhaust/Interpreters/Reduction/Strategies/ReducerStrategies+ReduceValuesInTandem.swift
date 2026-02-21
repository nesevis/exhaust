//
//  ReducerStrategies+ReduceValuesInTandem.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/2/2026.
//

extension ReducerStrategies {
    private struct TandemWindowPlan {
        let windowIndices: [Int]
        let tag: TypeTag
        let originalEntries: [(index: Int, entry: ChoiceSequenceValue)]
        let originalSemanticDistances: [UInt64]
        let disallowAwayMoves: Bool
        let usesFloatingSteps: Bool
        let searchUpward: Bool
        let distance: UInt64
    }

    private struct TandemWindowCandidate {
        let sequence: ChoiceSequence
        let changedEntries: [(index: Int, entry: ChoiceSequenceValue)]
    }

    /// Pass 7: Binary search multiple values toward their reduction target.
    /// For each sibling group of values will test how much it can reduce all siblings by the same amount.
    ///
    /// - Complexity: O(*g* · *w* · log *d* · *M*), where *g* is the number of sibling groups,
    ///   *w* is the number of tandem windows explored per group, *d* is the maximum bit-pattern
    ///   distance between a value and its reduction target, and *M* is the cost of a single oracle call.
    static func reduceValuesInTandem<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        siblingGroups: [SiblingGroup],
        rejectCache: inout ReducerCache,
        probeBudget: Int,
        onBudgetExhausted: ((String) -> Void)? = nil,
    ) throws -> (ChoiceSequence, Output)? {
        var current = sequence
        var progress = false
        var latestOutput: Output?
        var budget = ProbeBudget(passName: "reduceValuesInTandem", limit: probeBudget)
        var didReportBudgetExhaustion = false
        var budgetExhausted = false

        func reportBudgetExhaustionIfNeeded() {
            guard budget.isExhausted, didReportBudgetExhaustion == false else { return }
            didReportBudgetExhaustion = true
            onBudgetExhausted?(budget.exhaustionReason)
        }

        guard budget.isExhausted == false else {
            reportBudgetExhaustionIfNeeded()
            return nil
        }

        groupLoop: for group in siblingGroups {
            let tandemIndexSets = tandemIndexSets(for: group, in: current)
            guard tandemIndexSets.isEmpty == false else { continue }

            // Try suffix offsets so a near-target leading sibling does not block the whole set.
            for indexSet in tandemIndexSets where indexSet.count >= 2 {
                let windowPlans = tandemWindowPlans(
                    for: indexSet,
                    in: current,
                    groupKind: group.kind,
                )
                for plan in windowPlans {
                    if budgetExhausted {
                        break groupLoop
                    }

                    var lastProbeEntries: [(index: Int, entry: ChoiceSequenceValue)]?
                    var lastProbeOutput: Output?
                    var lastProbeDelta: UInt64 = 0

                    let bestDelta = AdaptiveProbe.binarySearchWithGuess(
                        { (delta: UInt64) -> Bool in
                            if budgetExhausted {
                                return false
                            }
                            guard delta > 0 else { return true } // predicate(0) assumed true
                            guard let probeCandidate = tandemCandidate(
                                plan: plan,
                                current: current,
                                delta: delta,
                            ) else {
                                return false
                            }

                            let probe = probeCandidate.sequence
                            guard rejectCache.contains(probe) == false else {
                                return false
                            }
                            guard budget.consume() else {
                                budgetExhausted = true
                                reportBudgetExhaustionIfNeeded()
                                return false
                            }
                            guard let output = try? Interpreters.materialize(gen, with: tree, using: probe) else {
                                rejectCache.insert(probe)
                                return false
                            }
                            let success = property(output) == false
                            if success {
                                if delta >= lastProbeDelta {
                                    lastProbeDelta = delta
                                    lastProbeOutput = output
                                    lastProbeEntries = probeCandidate.changedEntries
                                }
                            } else {
                                rejectCache.insert(probe)
                            }
                            return success
                        },
                        low: UInt64(0),
                        high: plan.distance,
                    )

                    if budgetExhausted {
                        break groupLoop
                    }

                    if bestDelta > 0,
                       lastProbeDelta == bestDelta,
                       let lastProbeOutput,
                       let lastProbeEntries
                    {
                        for (idx, entry) in lastProbeEntries {
                            current[idx] = entry
                        }
                        latestOutput = lastProbeOutput
                        progress = true
                        continue
                    }

                    if bestDelta > 0,
                       let fallbackCandidate = tandemCandidate(
                           plan: plan,
                           current: current,
                           delta: bestDelta,
                       )
                    {
                        let candidate = fallbackCandidate.sequence
                        guard rejectCache.contains(candidate) == false else {
                            continue
                        }
                        guard budget.consume() else {
                            budgetExhausted = true
                            reportBudgetExhaustionIfNeeded()
                            break groupLoop
                        }
                        guard let output = try? Interpreters.materialize(gen, with: tree, using: candidate),
                              property(output) == false
                        else {
                            rejectCache.insert(candidate)
                            continue
                        }

                        latestOutput = output
                        for (idx, entry) in fallbackCandidate.changedEntries {
                            current[idx] = entry
                        }
                        progress = true
                    }
                }
            }
        }

        if budgetExhausted {
            reportBudgetExhaustionIfNeeded()
        }

        if progress, let output = latestOutput {
            return (current, output)
        }
        return nil
    }

    private static func tandemWindowPlans(
        for indexSet: [Int],
        in sequence: ChoiceSequence,
        groupKind: SiblingChildKind,
    ) -> [TandemWindowPlan] {
        guard indexSet.count >= 2 else { return [] }

        var plans = [TandemWindowPlan]()
        plans.reserveCapacity(indexSet.count - 1)

        for offset in 0 ..< (indexSet.count - 1) {
            let windowIndices = Array(indexSet[offset...])
            guard let plan = makeTandemWindowPlan(
                windowIndices: windowIndices,
                in: sequence,
                groupKind: groupKind,
            ) else {
                continue
            }
            plans.append(plan)
        }

        return plans
    }

    private static func makeTandemWindowPlan(
        windowIndices: [Int],
        in sequence: ChoiceSequence,
        groupKind: SiblingChildKind,
    ) -> TandemWindowPlan? {
        guard let firstValueIndex = windowIndices.first,
              let firstValue = sequence[firstValueIndex].value
        else {
            return nil
        }

        let tag = firstValue.choice.tag
        guard supportsTandemTag(tag) else { return nil }
        guard windowIndices.dropFirst().allSatisfy({ idx in
            guard let value = sequence[idx].value else { return false }
            return value.choice.tag == tag
        }) else {
            return nil
        }

        let currentBP = firstValue.choice.bitPattern64
        let targetBP = firstValue.choice.reductionTarget(in: firstValue.validRanges)
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
                tag: tag,
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
            guard distance > 1 else { return nil }
        }

        let originalEntries: [(index: Int, entry: ChoiceSequenceValue)] = windowIndices.map { idx in
            (idx, sequence[idx])
        }
        let originalSemanticDistances: [UInt64] = originalEntries.compactMap { pair in
            pair.entry.value.map { semanticDistance(of: $0.choice) }
        }
        guard originalSemanticDistances.count == originalEntries.count else {
            return nil
        }

        return TandemWindowPlan(
            windowIndices: windowIndices,
            tag: tag,
            originalEntries: originalEntries,
            originalSemanticDistances: originalSemanticDistances,
            disallowAwayMoves: groupKind == .bareValue && windowIndices.count > 2,
            usesFloatingSteps: usesFloatingSteps,
            searchUpward: searchUpward,
            distance: distance,
        )
    }

    private static func tandemCandidate(
        plan: TandemWindowPlan,
        current: ChoiceSequence,
        delta: UInt64,
    ) -> TandemWindowCandidate? {
        guard delta > 0 else { return nil }

        var candidate = current
        var changedEntries = [(index: Int, entry: ChoiceSequenceValue)]()
        changedEntries.reserveCapacity(plan.windowIndices.count)

        var firstDifferenceOrder: ShortlexOrder = .eq
        var hasDifference = false
        for (entryOffset, pair) in plan.originalEntries.enumerated() {
            let idx = pair.index
            let originalEntry = pair.entry
            guard let value = originalEntry.value else { return nil }
            let newChoice: ChoiceValue
            if plan.usesFloatingSteps {
                guard case let .floating(currentFloatingValue, _, _) = value.choice else {
                    return nil
                }
                let signedDelta = plan.searchUpward ? Double(delta) : -Double(delta)
                let candidateFloatingValue = currentFloatingValue + signedDelta
                guard let floatingChoice = floatingChoice(from: candidateFloatingValue, tag: plan.tag) else {
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
                    tag: plan.tag,
                )
            }
            guard newChoice.fits(in: value.validRanges) else {
                continue
            }
            if plan.disallowAwayMoves {
                let beforeDistance = plan.originalSemanticDistances[entryOffset]
                let afterDistance = semanticDistance(of: newChoice)
                if afterDistance > beforeDistance {
                    return nil
                }
            }

            let newEntry = ChoiceSequenceValue.value(.init(
                choice: newChoice,
                validRanges: value.validRanges,
            ))
            let order = newEntry.shortLexCompare(originalEntry)
            guard order != .eq else { continue }

            if hasDifference == false {
                hasDifference = true
                firstDifferenceOrder = order
            }
            candidate[idx] = newEntry
            changedEntries.append((idx, newEntry))
        }

        guard hasDifference, firstDifferenceOrder == .lt else {
            return nil
        }

        return TandemWindowCandidate(sequence: candidate, changedEntries: changedEntries)
    }

    private static func tandemIndexSets(
        for group: SiblingGroup,
        in sequence: ChoiceSequence,
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

        // For container sibling groups, align values by internal value offset across siblings.
        let perSiblingValueIndices = group.ranges.map { range in
            valueIndices(in: sequence, within: range)
        }
        guard perSiblingValueIndices.count >= 2 else { return [] }
        let sharedValueCount = perSiblingValueIndices.map(\.count).min() ?? 0
        guard sharedValueCount > 0 else { return [] }

        var alignedSets = [[Int]]()
        alignedSets.reserveCapacity(sharedValueCount)
        for valueOffset in 0 ..< sharedValueCount {
            let aligned = perSiblingValueIndices.map { $0[valueOffset] }
            if aligned.count >= 2 {
                alignedSets.append(aligned)
            }
        }
        return alignedSets
    }

    private static func valueIndices(
        in sequence: ChoiceSequence,
        within range: ClosedRange<Int>,
    ) -> [Int] {
        var indices = [Int]()
        indices.reserveCapacity(range.count)
        for idx in range where sequence[idx].value != nil {
            indices.append(idx)
        }
        return indices
    }

    private static func supportsTandemTag(_ tag: TypeTag) -> Bool {
        switch tag {
        case .int, .int64, .int32, .int16, .int8, .uint, .uint64, .uint32, .uint16, .uint8, .double, .float:
            true
        case .character:
            false
        }
    }

    private static func semanticDistance(of value: ChoiceValue) -> UInt64 {
        let simplest = value.semanticSimplest
        let lhs = value.shortlexKey
        let rhs = simplest.shortlexKey
        return lhs >= rhs ? (lhs - rhs) : (rhs - lhs)
    }

    private static func floatingChoice(from value: Double, tag: TypeTag) -> ChoiceValue? {
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
