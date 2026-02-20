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
    ) throws -> (ChoiceSequence, Output)? {
        // Collect all numeric value/reduced entries with their sequence indices and container IDs.
        // Container ID increments each time we cross a container boundary (group/sequence close),
        // so values in different containers get different IDs.
        typealias Candidate = (index: Int, value: ChoiceSequenceValue.Value, containerID: Int)
        var candidatesByTag = [TypeTag: [Candidate]]()
        var containerID = 0

        for (i, entry) in sequence.enumerated() {
            switch entry {
            case .group(false), .sequence(false):
                containerID += 1
            case let .value(v), let .reduced(v):
                switch v.choice {
                case .unsigned, .signed, .floating:
                    candidatesByTag[v.choice.tag, default: []].append((i, v, containerID))
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
        var currentNonSemanticCount = nonSemanticValueCount(in: current)

        for (_, candidates) in candidatesByTag {
            guard candidates.count >= 2 else { continue }

            for ci in 0 ..< candidates.count {
                for cj in (ci + 1) ..< candidates.count {
                    // Try both orientations so index ordering does not block useful redistributions.
                    for (lhs, rhs) in [(ci, cj), (cj, ci)] {
                        let (idx1, _, _) = candidates[lhs]
                        let (idx2, _, _) = candidates[rhs]

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
                        let beforePair = [fresh1.choice.shortlexKey, fresh2.choice.shortlexKey].sorted()

                        let bestK = AdaptiveProbe.findInteger { (k: UInt64) -> Bool in
                            guard k > 0 else { return true }
                            guard k <= distance1 else { return false }

                            // Move node1 toward its target by k
                            let newBP1 = decrease1Upward ? bp1 + k : bp1 - k
                            // Move node2 away from its target by k (opposite direction)
                            let newBP2: UInt64
                            if decrease1Upward {
                                // node1 increases by k, so node2 must decrease by k
                                guard bp2 >= k else { return false }
                                newBP2 = bp2 - k
                            } else {
                                // node1 decreases by k, so node2 must increase by k
                                guard UInt64.max - k >= bp2 else { return false }
                                newBP2 = bp2 + k
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

                            var probe = current
                            probe[idx1] = .reduced(.init(choice: newChoice1, validRanges: fresh1.validRanges))
                            probe[idx2] = .value(.init(choice: newChoice2, validRanges: fresh2.validRanges))

                            let probeNonSemanticCount = nonSemanticValueCount(in: probe)
                            let improvesStructure = probe.shortLexPrecedes(current)
                                || probeNonSemanticCount < currentNonSemanticCount
                            guard improvesStructure else { return false }

                            guard rejectCache.contains(probe) == false else {
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
                                }
                            } else {
                                rejectCache.insert(probe)
                            }
                            return success
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
                            var bestFallbackNonSemantic = Int.max
                            for k in uniqueFallbackKs {
                                let newBP1 = decrease1Upward ? bp1 + k : bp1 - k
                                let newBP2: UInt64
                                if decrease1Upward {
                                    guard bp2 >= k else { continue }
                                    newBP2 = bp2 - k
                                } else {
                                    guard UInt64.max - k >= bp2 else { continue }
                                    newBP2 = bp2 + k
                                }

                                let newChoice1 = ChoiceValue(
                                    fresh1.choice.tag.makeConvertible(bitPattern64: newBP1),
                                    tag: fresh1.choice.tag,
                                )
                                let newChoice2 = ChoiceValue(
                                    fresh2.choice.tag.makeConvertible(bitPattern64: newBP2),
                                    tag: fresh2.choice.tag,
                                )

                                var probe = current
                                probe[idx1] = .reduced(.init(choice: newChoice1, validRanges: fresh1.validRanges))
                                probe[idx2] = .value(.init(choice: newChoice2, validRanges: fresh2.validRanges))

                                let probeNonSemanticCount = nonSemanticValueCount(in: probe)
                                let improvesStructure = probe.shortLexPrecedes(current)
                                    || probeNonSemanticCount < currentNonSemanticCount
                                guard improvesStructure else { continue }

                                let afterPair = [newChoice1.shortlexKey, newChoice2.shortlexKey].sorted()
                                guard afterPair != beforePair else { continue }
                                guard rejectCache.contains(probe) == false else { continue }
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
                                    bestFallbackNonSemantic = probeNonSemanticCount
                                }
                            }

                            if let bestFallbackProbe, let bestFallbackOutput {
                                lastProbe = bestFallbackProbe
                                lastProbeOutput = bestFallbackOutput
                            }
                        }

                        if let probe = lastProbe,
                           let output = lastProbeOutput,
                           (probe.shortLexPrecedes(current)
                               || nonSemanticValueCount(in: probe) < currentNonSemanticCount)
                        {
                            current = probe
                            latestOutput = output
                            progress = true
                            currentNonSemanticCount = nonSemanticValueCount(in: current)
                        }
                    }
                }
            }
        }

        if progress, let output = latestOutput {
            return (current, output)
        }
        return nil
    }

    private static func absDiff(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs >= rhs ? (lhs - rhs) : (rhs - lhs)
    }

    private static func nonSemanticValueCount(in sequence: ChoiceSequence) -> Int {
        sequence.reduce(into: 0) { count, entry in
            guard let value = entry.value else { return }
            if value.choice.shortlexKey != value.choice.semanticSimplest.shortlexKey {
                count += 1
            }
        }
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
}
