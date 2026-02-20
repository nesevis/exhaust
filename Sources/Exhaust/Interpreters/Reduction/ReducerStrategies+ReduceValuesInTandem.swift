//
//  ReducerStrategies+ReduceValuesInTandem.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/2/2026.
//

extension ReducerStrategies {
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
    ) throws -> (ChoiceSequence, Output)? {
        var current = sequence
        var progress = false
        var latestOutput: Output?

        for group in siblingGroups {
            let tandemIndexSets = tandemIndexSets(for: group, in: current)
            guard tandemIndexSets.isEmpty == false else { continue }

            // Try suffix offsets so a near-target leading sibling does not block the whole set.
            for indexSet in tandemIndexSets where indexSet.count >= 2 {
                for offset in 0 ..< (indexSet.count - 1) {
                    let windowIndices = Array(indexSet[offset...])
                    guard let firstValueIndex = windowIndices.first,
                          let firstValue = current[firstValueIndex].value
                    else {
                        continue
                    }

                    // Keep tandem adjustments type-homogeneous.
                    let tag = firstValue.choice.tag
                    guard supportsTandemTag(tag) else { continue }
                    guard windowIndices.dropFirst().allSatisfy({ idx in
                        guard let value = current[idx].value else { return false }
                        return value.choice.tag == tag
                    }) else {
                        continue
                    }

                    let currentBP = firstValue.choice.bitPattern64
                    let targetBP = firstValue.choice.reductionTarget(in: firstValue.validRanges)
                    guard currentBP != targetBP else { continue }

                    let searchUpward = targetBP > currentBP
                    let distance = searchUpward
                        ? targetBP - currentBP
                        : currentBP - targetBP
                    guard distance > 1 else { continue }

                    let originalEntries: [(index: Int, entry: ChoiceSequenceValue)] = windowIndices.map { idx in
                        (idx, current[idx])
                    }
                    let originalSemanticDistances: [Int: UInt64] = Dictionary(
                        uniqueKeysWithValues: originalEntries.compactMap { pair in
                            guard let value = pair.entry.value else { return nil }
                            return (pair.index, semanticDistance(of: value.choice))
                        },
                    )
                    // For high-arity bare-value windows, disallow "translation" moves that
                    // make any sibling semantically farther away. This keeps tandem monotone.
                    let disallowAwayMoves = group.kind == .bareValue && windowIndices.count > 2
                    var probe = current
                    var lastProbeEntries: [(index: Int, entry: ChoiceSequenceValue)]?
                    var lastProbeOutput: Output?
                    var lastProbeDelta: UInt64 = 0

                    let bestDelta = AdaptiveProbe.binarySearchWithGuess(
                        { (delta: UInt64) -> Bool in
                            guard delta > 0 else { return true } // predicate(0) assumed true
                            var firstDifferenceOrder: ShortlexOrder = .eq
                            var hasDifference = false
                            var hasAwayMove = false
                            for (idx, originalEntry) in originalEntries {
                                guard let v = current[idx].value else {
                                    return true
                                }
                                let newValue = searchUpward
                                    ? v.choice.bitPattern64 &+ delta
                                    : v.choice.bitPattern64 &- delta
                                let newChoice = ChoiceValue(
                                    v.choice.tag.makeConvertible(bitPattern64: newValue),
                                    tag: v.choice.tag,
                                )
                                guard newChoice.fits(in: v.validRanges) else {
                                    probe[idx] = originalEntry
                                    continue
                                }
                                let newEntry = ChoiceSequenceValue.value(.init(choice: newChoice, validRanges: v.validRanges))
                                if disallowAwayMoves,
                                   let beforeDistance = originalSemanticDistances[idx]
                                {
                                    let afterDistance = semanticDistance(of: newChoice)
                                    if afterDistance > beforeDistance {
                                        hasAwayMove = true
                                        break
                                    }
                                }
                                let order = newEntry.shortLexCompare(originalEntry)
                                if order != .eq, hasDifference == false {
                                    hasDifference = true
                                    firstDifferenceOrder = order
                                }
                                probe[idx] = newEntry
                            }

                            if hasAwayMove {
                                return false
                            }
                            guard hasDifference, firstDifferenceOrder == .lt else {
                                return false
                            }

                            guard rejectCache.contains(probe) == false else {
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
                                    lastProbeEntries = originalEntries.map { ($0.index, probe[$0.index]) }
                                }
                            } else {
                                rejectCache.insert(probe)
                            }
                            return success
                        },
                        low: UInt64(0),
                        high: distance,
                    )

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

                    if bestDelta > 0 {
                        // Fallback: reconstruct accepted candidate if probe bookkeeping missed it.
                        var candidate = current
                        var firstDifferenceOrder: ShortlexOrder = .eq
                        var hasDifference = false
                        var hasAwayMove = false
                        for idx in windowIndices {
                            guard let v = current[idx].value else { continue }
                            let newValue = searchUpward
                                ? v.choice.bitPattern64 &+ bestDelta
                                : v.choice.bitPattern64 &- bestDelta
                            let newChoice = ChoiceValue(
                                v.choice.tag.makeConvertible(bitPattern64: newValue),
                                tag: v.choice.tag,
                            )
                            guard newChoice.fits(in: v.validRanges) else { continue }
                            let newEntry = ChoiceSequenceValue.value(.init(choice: newChoice, validRanges: v.validRanges))
                            if disallowAwayMoves,
                               let beforeDistance = originalSemanticDistances[idx]
                            {
                                let afterDistance = semanticDistance(of: newChoice)
                                if afterDistance > beforeDistance {
                                    hasAwayMove = true
                                    break
                                }
                            }
                            let order = newEntry.shortLexCompare(current[idx])
                            guard order != .eq else { continue }
                            if hasDifference == false {
                                hasDifference = true
                                firstDifferenceOrder = order
                            }
                            candidate[idx] = newEntry
                        }
                        if hasAwayMove == false,
                           hasDifference, firstDifferenceOrder == .lt,
                           let output = try? Interpreters.materialize(gen, with: tree, using: candidate),
                           property(output) == false
                        {
                            latestOutput = output
                            current = candidate
                            progress = true
                        } else {
                            rejectCache.insert(candidate)
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

    private static func tandemIndexSets(
        for group: SiblingGroup,
        in sequence: ChoiceSequence,
    ) -> [[Int]] {
        if let valueRanges = group.valueRanges, valueRanges.count >= 2 {
            return [valueRanges.map(\.lowerBound)]
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
        case .int, .int64, .int32, .int16, .int8, .uint, .uint64, .uint32, .uint16, .uint8:
            true
        case .double, .float, .character:
            false
        }
    }

    private static func semanticDistance(of value: ChoiceValue) -> UInt64 {
        let simplest = value.semanticSimplest
        let lhs = value.shortlexKey
        let rhs = simplest.shortlexKey
        return lhs >= rhs ? (lhs - rhs) : (rhs - lhs)
    }
}
