//
//  ReducerStrategies+RedistributeNumericPairs.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/2/2026.
//

extension ReducerStrategies {
    private struct FloatRedistributionContext {
        let lhsNumerator: Int64
        let rhsNumerator: Int64
        let denominator: UInt64
        let lhsMovesUpward: Bool
        let distance: UInt64
    }

    /// Pass 5b: Cross-container value redistribution.
    /// For each pair of numeric values with the same tag, tries to decrease the earlier value
    /// (toward its reduction target) while increasing the later value by the same amount k.
    /// This enables reduction when values in different containers are coupled.
    ///
    /// - Complexity: O(*s* + *v*² · log *d* · *M*), where *s* is the sequence length,
    ///   *v* is the number of numeric values (bounded to ≤ 16 by the caller), *d* is the maximum
    ///   bit-pattern distance, and *M* is the cost of a single property invocation. Iterates over O(*v*²)
    ///   cross-container pairs, each invoking `findInteger` with O(log *d*) property invocations.
    static func redistributeNumericPairs<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        rejectCache: inout ReducerCache,
        probeBudget: Int,
        onBudgetExhausted: ((String) -> Void)? = nil,
    ) throws -> (ChoiceSequence, Output)? {
        typealias Candidate = (index: Int, value: ChoiceSequenceValue.Value)
        var candidatesByTag = [TypeTag: [Candidate]]()
        var budget = ProbeBudget(passName: "redistributeNumericPairs", limit: probeBudget)
        var didReportBudgetExhaustion = false

        func reportBudgetExhaustionIfNeeded() {
            guard budget.isExhausted, didReportBudgetExhaustion == false else { return }
            didReportBudgetExhaustion = true
            onBudgetExhausted?(budget.exhaustionReason)
        }

        guard budget.isExhausted == false else {
            reportBudgetExhaustionIfNeeded()
            return nil
        }

        for (i, entry) in sequence.enumerated() {
            switch entry {
            case let .value(v), let .reduced(v):
                switch v.choice {
                case .unsigned, .signed, .floating:
                    candidatesByTag[v.choice.tag, default: []].append((i, v))
                }
            default:
                break
            }
        }

        var current = sequence
        var progress = false
        var latestOutput: Output?
        var semanticStats = SequenceSemanticStats(sequence: current)
        var currentNonSemanticCount = semanticStats.nonSemanticCount
        var budgetExhausted = false

        candidateLoop: for (_, candidates) in candidatesByTag {
            guard candidates.count >= 2 else { continue }

            for ci in 0 ..< candidates.count {
                for cj in (ci + 1) ..< candidates.count {
                    // Try both orientations so index ordering does not block useful redistributions.
                    for (lhs, rhs) in [(ci, cj), (cj, ci)] {
                        if budgetExhausted {
                            break candidateLoop
                        }

                        let (idx1, _) = candidates[lhs]
                        let (idx2, _) = candidates[rhs]

                        // Use current values (may have been updated by prior iterations)
                        guard let fresh1 = current[idx1].value,
                              let fresh2 = current[idx2].value else { continue }

                        let bp1 = fresh1.choice.bitPattern64
                        let target1 = fresh1.choice.reductionTarget(in: fresh1.validRange)
                        let floatContext = makeFloatRedistributionContext(
                            lhs: fresh1.choice,
                            rhs: fresh2.choice,
                            lhsTargetBitPattern: target1,
                        )
                        let decrease1Upward: Bool
                        let distance1: UInt64
                        if let floatContext {
                            decrease1Upward = floatContext.lhsMovesUpward
                            distance1 = floatContext.distance
                        } else {
                            guard bp1 != target1 else { continue }
                            decrease1Upward = target1 > bp1
                            distance1 = decrease1Upward
                                ? target1 - bp1
                                : bp1 - target1
                        }
                        guard distance1 > 0 else { continue }

                        // Use semantic shortlex distance for gating heuristics so signed values
                        // near zero (e.g. -1) are treated as near, not "far" by raw bit patterns.
                        let semanticDistance1 = absDiff(
                            fresh1.choice.shortlexKey,
                            fresh1.choice.semanticSimplest.shortlexKey,
                        )
                        let semanticDistance2 = absDiff(
                            fresh2.choice.shortlexKey,
                            fresh2.choice.semanticSimplest.shortlexKey,
                        )

                        // Skip if node2 is already at its target — no point moving it away.
                        guard semanticDistance2 > 0 else { continue }

                        // Only redistribute when node1 is far enough from its target to justify the
                        // disruption to node2. Small distances are better handled by independent reduction.
                        guard semanticDistance1 > 16 else { continue }

                        var lastProbe: ChoiceSequence?
                        var lastProbeOutput: Output?
                        var lastProbeEntry1: ChoiceSequenceValue?
                        var lastProbeEntry2: ChoiceSequenceValue?
                        var lastProbeNonSemanticCount = Int.max
                        let beforePair = [fresh1.choice.shortlexKey, fresh2.choice.shortlexKey].sorted()

                        _ = AdaptiveProbe.findInteger { (k: UInt64) -> Bool in
                            if budgetExhausted {
                                return false
                            }
                            guard k > 0 else { return true }
                            guard k <= distance1 else { return false }

                            guard let (newChoice1, newChoice2) = redistributedPairChoices(
                                lhs: fresh1.choice,
                                rhs: fresh2.choice,
                                delta: k,
                                lhsMovesUpward: decrease1Upward,
                                floatContext: floatContext,
                            ) else {
                                return false
                            }
                            if floatContext != nil {
                                if fresh1.isRangeExplicit, newChoice1.fits(in: fresh1.validRange) == false {
                                    return false
                                }
                                if fresh2.isRangeExplicit, newChoice2.fits(in: fresh2.validRange) == false {
                                    return false
                                }
                            }

                            // Do not range-gate here: recorded valid ranges can be stale after prior
                            // structural/value edits. Let replay/materialization be the source of truth.
                            let probeEntry1 = ChoiceSequenceValue.reduced(.init(
                                choice: newChoice1,
                                validRange: fresh1.validRange,
                                isRangeExplicit: fresh1.isRangeExplicit,
                            ))
                            let probeEntry2 = ChoiceSequenceValue.value(.init(
                                choice: newChoice2,
                                validRange: fresh2.validRange,
                                isRangeExplicit: fresh2.isRangeExplicit,
                            ))
                            let probeNonSemanticCount = semanticStats.nonSemanticCount(
                                afterReplacing: (idx1, probeEntry1),
                                and: (idx2, probeEntry2),
                            )

                            var probe = current
                            probe[idx1] = probeEntry1
                            probe[idx2] = probeEntry2

                            #if DEBUG
                                assert(
                                    SequenceSemanticStats.fullNonSemanticCount(in: probe) == probeNonSemanticCount,
                                    "SequenceSemanticStats delta mismatch in redistributeNumericPairs",
                                )
                            #endif

                            let afterPair = [newChoice1.shortlexKey, newChoice2.shortlexKey].sorted()
                            let improvesStructure = probe.shortLexPrecedes(current)
                                || probeNonSemanticCount < currentNonSemanticCount
                                || afterPair.lexicographicallyPrecedes(beforePair)
                            guard improvesStructure else { return false }

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
                                // Record only probes that actually change the pair multiset.
                                // This avoids committing pure cross-container swaps like (-1, -32768) <-> (-32768, -1),
                                // while still allowing the monotone search to continue probing larger k.
                                if afterPair != beforePair {
                                    lastProbe = probe
                                    lastProbeOutput = output
                                    lastProbeEntry1 = probeEntry1
                                    lastProbeEntry2 = probeEntry2
                                    lastProbeNonSemanticCount = probeNonSemanticCount
                                }
                            } else {
                                rejectCache.insert(probe)
                            }
                            return success
                        }

                        if budgetExhausted {
                            break candidateLoop
                        }

                        if lastProbe == nil {
                            // Non-monotonic fallback: useful redistributions can fail for small k
                            // but succeed for larger k (e.g. wrapping from small positive -> Int16.min).
                            var fallbackKs = [distance1]
                            if distance1 > 1 { fallbackKs.append(distance1 - 1) }
                            fallbackKs.append(max(1, distance1 / 2))
                            fallbackKs.append(max(1, distance1 / 4))
                            if floatContext == nil,
                               let wrapK = wrappingBoundaryDelta(for: fresh2.choice.tag, bitPattern: fresh2.choice.bitPattern64),
                               wrapK > 0,
                               wrapK <= distance1
                            {
                                fallbackKs.append(wrapK)
                                if wrapK > 1 { fallbackKs.append(wrapK - 1) }
                            }
                            let uniqueFallbackKs = Array(Set(fallbackKs))
                                .filter { $0 > 0 && $0 <= distance1 }
                                .sorted(by: >)

                            var bestFallbackProbe: ChoiceSequence?
                            var bestFallbackOutput: Output?
                            var bestFallbackEntry1: ChoiceSequenceValue?
                            var bestFallbackEntry2: ChoiceSequenceValue?
                            var bestFallbackNonSemantic = Int.max
                            for k in uniqueFallbackKs {
                                guard let (newChoice1, newChoice2) = redistributedPairChoices(
                                    lhs: fresh1.choice,
                                    rhs: fresh2.choice,
                                    delta: k,
                                    lhsMovesUpward: decrease1Upward,
                                    floatContext: floatContext,
                                ) else {
                                    continue
                                }
                                if floatContext != nil {
                                    if fresh1.isRangeExplicit, newChoice1.fits(in: fresh1.validRange) == false {
                                        continue
                                    }
                                    if fresh2.isRangeExplicit, newChoice2.fits(in: fresh2.validRange) == false {
                                        continue
                                    }
                                }

                                let probeEntry1 = ChoiceSequenceValue.reduced(.init(
                                    choice: newChoice1,
                                    validRange: fresh1.validRange,
                                    isRangeExplicit: fresh1.isRangeExplicit,
                                ))
                                let probeEntry2 = ChoiceSequenceValue.value(.init(
                                    choice: newChoice2,
                                    validRange: fresh2.validRange,
                                    isRangeExplicit: fresh2.isRangeExplicit,
                                ))

                                var probe = current
                                probe[idx1] = probeEntry1
                                probe[idx2] = probeEntry2

                                let probeNonSemanticCount = semanticStats.nonSemanticCount(
                                    afterReplacing: (idx1, probeEntry1),
                                    and: (idx2, probeEntry2),
                                )
                                #if DEBUG
                                    assert(
                                        SequenceSemanticStats.fullNonSemanticCount(in: probe) == probeNonSemanticCount,
                                        "SequenceSemanticStats delta mismatch in redistributeNumericPairs fallback",
                                    )
                                #endif
                                let afterPair = [newChoice1.shortlexKey, newChoice2.shortlexKey].sorted()
                                let improvesStructure = probe.shortLexPrecedes(current)
                                    || probeNonSemanticCount < currentNonSemanticCount
                                    || afterPair.lexicographicallyPrecedes(beforePair)
                                guard improvesStructure else { continue }
                                guard afterPair != beforePair else { continue }
                                guard rejectCache.contains(probe) == false else { continue }
                                guard budget.consume() else {
                                    budgetExhausted = true
                                    reportBudgetExhaustionIfNeeded()
                                    break
                                }
                                guard let output = try? Interpreters.materialize(gen, with: tree, using: probe) else {
                                    rejectCache.insert(probe)
                                    continue
                                }
                                guard property(output) == false else {
                                    rejectCache.insert(probe)
                                    continue
                                }

                                if bestFallbackProbe == nil
                                    || probeNonSemanticCount < bestFallbackNonSemantic
                                    || (probeNonSemanticCount == bestFallbackNonSemantic
                                        && probe.shortLexPrecedes(bestFallbackProbe!))
                                {
                                    bestFallbackProbe = probe
                                    bestFallbackOutput = output
                                    bestFallbackEntry1 = probeEntry1
                                    bestFallbackEntry2 = probeEntry2
                                    bestFallbackNonSemantic = probeNonSemanticCount
                                }
                            }
                            if budgetExhausted {
                                break candidateLoop
                            }

                            if let bestFallbackProbe, let bestFallbackOutput {
                                lastProbe = bestFallbackProbe
                                lastProbeOutput = bestFallbackOutput
                                lastProbeEntry1 = bestFallbackEntry1
                                lastProbeEntry2 = bestFallbackEntry2
                                lastProbeNonSemanticCount = bestFallbackNonSemantic
                            }
                        }

                        if let probe = lastProbe,
                           let output = lastProbeOutput,
                           let probeEntry1 = lastProbeEntry1,
                           let probeEntry2 = lastProbeEntry2
                        {
                            let afterPairSorted = [probeEntry1.value!.choice.shortlexKey, probeEntry2.value!.choice.shortlexKey].sorted()
                            guard probe.shortLexPrecedes(current)
                                || lastProbeNonSemanticCount < currentNonSemanticCount
                                || afterPairSorted.lexicographicallyPrecedes(beforePair)
                            else { continue }
                            current = probe
                            latestOutput = output
                            progress = true
                            semanticStats.applyReplacements(
                                (idx1, probeEntry1),
                                (idx2, probeEntry2),
                            )
                            currentNonSemanticCount = semanticStats.nonSemanticCount
                        }
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

    private static func makeFloatRedistributionContext(
        lhs: ChoiceValue,
        rhs: ChoiceValue,
        lhsTargetBitPattern: UInt64,
    ) -> FloatRedistributionContext? {
        let tag = lhs.tag
        guard tag == rhs.tag, tag == .double || tag == .float else {
            return nil
        }
        guard case let .floating(lhsValue, _, _) = lhs,
              case let .floating(rhsValue, _, _) = rhs,
              lhsValue.isFinite,
              rhsValue.isFinite
        else {
            return nil
        }

        let targetChoice = ChoiceValue(
            tag.makeConvertible(bitPattern64: lhsTargetBitPattern),
            tag: tag,
        )
        guard case let .floating(targetValue, _, _) = targetChoice,
              targetValue.isFinite
        else {
            return nil
        }

        guard let lhsRatio = FloatShrink.integerRatio(for: lhsValue, tag: tag),
              let rhsRatio = FloatShrink.integerRatio(for: rhsValue, tag: tag),
              let targetRatio = FloatShrink.integerRatio(for: targetValue, tag: tag),
              let lhsAndRhsDenominator = leastCommonMultiple(lhsRatio.denominator, rhsRatio.denominator),
              let denominator = leastCommonMultiple(lhsAndRhsDenominator, targetRatio.denominator),
              denominator > 0
        else {
            return nil
        }

        guard let lhsNumerator = scaledNumerator(lhsRatio, to: denominator),
              let rhsNumerator = scaledNumerator(rhsRatio, to: denominator),
              let targetNumerator = scaledNumerator(targetRatio, to: denominator)
        else {
            return nil
        }

        let lhsMovesUpward = targetNumerator > lhsNumerator
        let rawDistance = absDiff(lhsNumerator, targetNumerator)
        guard rawDistance > 0 else {
            return nil
        }

        return .init(
            lhsNumerator: lhsNumerator,
            rhsNumerator: rhsNumerator,
            denominator: denominator,
            lhsMovesUpward: lhsMovesUpward,
            distance: rawDistance,
        )
    }

    private static func scaledNumerator(
        _ ratio: (numerator: Int64, denominator: UInt64),
        to denominator: UInt64,
    ) -> Int64? {
        guard denominator % ratio.denominator == 0 else {
            return nil
        }
        let scale = denominator / ratio.denominator
        guard scale <= UInt64(Int64.max) else {
            return nil
        }
        let (scaled, overflow) = ratio.numerator.multipliedReportingOverflow(by: Int64(scale))
        guard overflow == false else {
            return nil
        }
        return scaled
    }

    private static func greatestCommonDivisor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        var a = lhs
        var b = rhs
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return a
    }

    private static func leastCommonMultiple(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        guard lhs > 0, rhs > 0 else {
            return nil
        }
        let gcd = greatestCommonDivisor(lhs, rhs)
        let reducedLHS = lhs / gcd
        let (product, overflow) = reducedLHS.multipliedReportingOverflow(by: rhs)
        guard overflow == false else {
            return nil
        }
        return product
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

    private static func absDiff(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs >= rhs ? (lhs - rhs) : (rhs - lhs)
    }

    private static func absDiff(_ lhs: Int64, _ rhs: Int64) -> UInt64 {
        if lhs >= rhs {
            return UInt64(lhs &- rhs)
        }
        return UInt64(rhs &- lhs)
    }

    private static func wrappingBoundaryDelta(for tag: TypeTag, bitPattern: UInt64) -> UInt64? {
        let modulus: UInt64? = switch tag {
        case .int8, .uint8:
            1 << 8
        case .int16, .uint16:
            1 << 16
        case .int32, .uint32:
            1 << 32
        default:
            nil
        }
        guard let modulus, modulus > 0 else { return nil }
        let remainder = bitPattern % modulus
        if remainder == 0 { return nil }
        return modulus - remainder
    }

    private static func redistributedPairBitPatterns(
        lhsBitPattern: UInt64,
        rhsBitPattern: UInt64,
        delta: UInt64,
        lhsMovesUpward: Bool,
    ) -> (UInt64, UInt64)? {
        if lhsMovesUpward {
            guard UInt64.max - delta >= lhsBitPattern else { return nil }
            guard rhsBitPattern >= delta else { return nil }
            return (lhsBitPattern + delta, rhsBitPattern - delta)
        }

        guard lhsBitPattern >= delta else { return nil }
        guard UInt64.max - delta >= rhsBitPattern else { return nil }
        return (lhsBitPattern - delta, rhsBitPattern + delta)
    }

    private static func redistributedPairChoices(
        lhs: ChoiceValue,
        rhs: ChoiceValue,
        delta: UInt64,
        lhsMovesUpward: Bool,
        floatContext: FloatRedistributionContext?,
    ) -> (ChoiceValue, ChoiceValue)? {
        if let floatContext {
            guard delta <= UInt64(Int64.max), delta <= floatContext.distance else {
                return nil
            }
            let signedDelta = Int64(delta)
            let lhsNumerator: Int64
            let rhsNumerator: Int64
            if lhsMovesUpward {
                let (lhsCandidate, lhsOverflow) = floatContext.lhsNumerator.addingReportingOverflow(signedDelta)
                let (rhsCandidate, rhsOverflow) = floatContext.rhsNumerator.subtractingReportingOverflow(signedDelta)
                guard lhsOverflow == false, rhsOverflow == false else {
                    return nil
                }
                lhsNumerator = lhsCandidate
                rhsNumerator = rhsCandidate
            } else {
                let (lhsCandidate, lhsOverflow) = floatContext.lhsNumerator.subtractingReportingOverflow(signedDelta)
                let (rhsCandidate, rhsOverflow) = floatContext.rhsNumerator.addingReportingOverflow(signedDelta)
                guard lhsOverflow == false, rhsOverflow == false else {
                    return nil
                }
                lhsNumerator = lhsCandidate
                rhsNumerator = rhsCandidate
            }

            let denominator = Double(floatContext.denominator)
            let lhsValue = Double(lhsNumerator) / denominator
            let rhsValue = Double(rhsNumerator) / denominator
            guard let newChoice1 = floatingChoice(from: lhsValue, tag: lhs.tag),
                  let newChoice2 = floatingChoice(from: rhsValue, tag: rhs.tag)
            else {
                return nil
            }
            return (newChoice1, newChoice2)
        }

        guard let (newBP1, newBP2) = redistributedPairBitPatterns(
            lhsBitPattern: lhs.bitPattern64,
            rhsBitPattern: rhs.bitPattern64,
            delta: delta,
            lhsMovesUpward: lhsMovesUpward,
        ) else {
            return nil
        }

        let newChoice1 = ChoiceValue(
            lhs.tag.makeConvertible(bitPattern64: newBP1),
            tag: lhs.tag,
        )
        let newChoice2 = ChoiceValue(
            rhs.tag.makeConvertible(bitPattern64: newBP2),
            tag: rhs.tag,
        )
        return (newChoice1, newChoice2)
    }
}
