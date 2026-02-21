//
//  ReducerStrategies+RedistributeNumericPairs.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/2/2026.
//

extension ReducerStrategies {
    /// Pass 5b: Cross-container value redistribution.
    /// For each pair of numeric values with the same tag, tries to decrease the earlier value
    /// (toward its reduction target) while increasing the later value by the same amount k.
    /// This enables reduction when values in different containers are coupled.
    ///
    /// - Complexity: O(*s* + *v*² · log *d* · *M*), where *s* is the sequence length,
    ///   *v* is the number of numeric values (bounded to ≤ 16 by the caller), *d* is the maximum
    ///   bit-pattern distance, and *M* is the cost of a single oracle call. Iterates over O(*v*²)
    ///   cross-container pairs, each invoking `findInteger` with O(log *d*) oracle calls.
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
                case .character:
                    break
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
                        let target1 = fresh1.choice.reductionTarget(in: fresh1.validRanges)
                        guard bp1 != target1 else { continue }

                        let bp2 = fresh2.choice.bitPattern64

                        // Determine direction: move bp1 toward target1
                        let decrease1Upward = target1 > bp1
                        let distance1 = decrease1Upward
                            ? target1 - bp1
                            : bp1 - target1

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

                            guard let (newBP1, newBP2) = redistributedPairBitPatterns(
                                lhsBitPattern: bp1,
                                rhsBitPattern: bp2,
                                delta: k,
                                lhsMovesUpward: decrease1Upward
                            ) else {
                                return false
                            }

                            let newChoice1 = ChoiceValue(
                                fresh1.choice.tag.makeConvertible(bitPattern64: newBP1),
                                tag: fresh1.choice.tag,
                            )
                            let newChoice2 = ChoiceValue(
                                fresh2.choice.tag.makeConvertible(bitPattern64: newBP2),
                                tag: fresh2.choice.tag,
                            )
                            // Do not range-gate here: recorded valid ranges can be stale after prior
                            // structural/value edits. Let replay/materialization be the source of truth.
                            let probeEntry1 = ChoiceSequenceValue.reduced(.init(
                                choice: newChoice1,
                                validRanges: fresh1.validRanges,
                            ))
                            let probeEntry2 = ChoiceSequenceValue.value(.init(
                                choice: newChoice2,
                                validRanges: fresh2.validRanges,
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

                            let improvesStructure = probe.shortLexPrecedes(current)
                                || probeNonSemanticCount < currentNonSemanticCount
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
                                let afterPair = [newChoice1.shortlexKey, newChoice2.shortlexKey].sorted()
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
                            if let wrapK = wrappingBoundaryDelta(for: fresh2.choice.tag, bitPattern: bp2),
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
                                guard let (newBP1, newBP2) = redistributedPairBitPatterns(
                                    lhsBitPattern: bp1,
                                    rhsBitPattern: bp2,
                                    delta: k,
                                    lhsMovesUpward: decrease1Upward
                                ) else {
                                    continue
                                }

                                let newChoice1 = ChoiceValue(
                                    fresh1.choice.tag.makeConvertible(bitPattern64: newBP1),
                                    tag: fresh1.choice.tag,
                                )
                                let newChoice2 = ChoiceValue(
                                    fresh2.choice.tag.makeConvertible(bitPattern64: newBP2),
                                    tag: fresh2.choice.tag,
                                )
                                let probeEntry1 = ChoiceSequenceValue.reduced(.init(
                                    choice: newChoice1,
                                    validRanges: fresh1.validRanges,
                                ))
                                let probeEntry2 = ChoiceSequenceValue.value(.init(
                                    choice: newChoice2,
                                    validRanges: fresh2.validRanges,
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
                                let improvesStructure = probe.shortLexPrecedes(current)
                                    || probeNonSemanticCount < currentNonSemanticCount
                                guard improvesStructure else { continue }

                                let afterPair = [newChoice1.shortlexKey, newChoice2.shortlexKey].sorted()
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
                           let probeEntry2 = lastProbeEntry2,
                           (probe.shortLexPrecedes(current)
                               || lastProbeNonSemanticCount < currentNonSemanticCount)
                        {
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

    private static func absDiff(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs >= rhs ? (lhs - rhs) : (rhs - lhs)
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
}
