//
//  ReducerStrategies+ReduceValues.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/2/2026.
//

extension ReducerStrategies {
    /// Pass 5: Binary search each individual value toward its reduction target.
    /// For each `.value` entry, computes the ideal target (semantic simplest clamped to valid ranges),
    /// then binary searches between the current bit pattern and the target to find the minimum failing value.
    ///
    /// - Complexity: O(*n* · log *d* · *M*), where *n* is the number of value spans, *d* is the
    ///   maximum bit-pattern distance between a value and its reduction target, and *M* is the cost
    ///   of a single oracle call. The binary search with guess for each value makes O(log *d*) oracle
    ///   calls; the constant-size boundary probe (5 offsets) is dominated.
    static func reduceValues<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        valueSpans: [ChoiceSpan],
        rejectCache: inout ReducerCache
    ) throws -> (ChoiceSequence, Output)? {
        var current = sequence
        var progress = false
        var latestOutput: Output?

        for span in valueSpans {
            let seqIdx = span.range.lowerBound
            guard let v = current[seqIdx].value else { continue }

            let validRanges = v.validRanges
            let choiceTag = v.choice.tag
            let currentBP = v.choice.bitPattern64
            let targetBP = v.choice.reductionTarget(in: validRanges)

            guard currentBP != targetBP else { continue }

            let searchUpward = targetBP > currentBP
            let distance = searchUpward
                ? targetBP - currentBP
                : currentBP - targetBP
            let containingRange = validRanges.first(where: { $0.contains(currentBP) })
            let fastMaxDelta: UInt64? = {
                guard validRanges.count == 1, let containingRange else { return nil }
                return searchUpward
                    ? (containingRange.upperBound - currentBP)
                    : (currentBP - containingRange.lowerBound)
            }()

            // Try target directly
            let targetChoice = ChoiceValue(
                choiceTag.makeConvertible(bitPattern64: targetBP),
                tag: choiceTag
            )
            let targetEntry = ChoiceSequenceValue.reduced(.init(choice: targetChoice, validRanges: validRanges))
            var candidate = current
            candidate[seqIdx] = targetEntry
            if targetEntry.shortLexCompare(current[seqIdx]) == .lt, rejectCache.contains(candidate) == false {
                if let output = try? Interpreters.materialize(gen, with: tree, using: candidate),
                   property(output) == false
                {
                    current = candidate
                    latestOutput = output
                    progress = true
                    continue
                } else {
                    rejectCache.insert(candidate)
                }
            }

            // Binary search: predicate(delta) means "can we move delta steps toward the target and still fail?"
            // predicate(0) = true (no change), predicate(distance) = false (target was just rejected)
            guard distance > 1 else { continue }
            let originalEntry = current[seqIdx]
            var probe = current
            var bestProbeEntry: ChoiceSequenceValue?
            var bestProbeOutput: Output?
            var bestProbeDelta: UInt64 = 0

            // Compute a guess: midpoint of the containing valid range, converted to delta space
            let guess: UInt64? = {
                guard let containingRange else {
                    return nil
                }
                let rangeMid = containingRange.lowerBound / 2 + containingRange.upperBound / 2
                let guessDelta: UInt64
                if searchUpward {
                    guessDelta = rangeMid > currentBP ? rangeMid - currentBP : 0
                } else {
                    guessDelta = currentBP > rangeMid ? currentBP - rangeMid : 0
                }
                // Clamp to valid delta range [0, distance)
                guard guessDelta > 0, guessDelta < distance else { return nil }
                return guessDelta
            }()

            let bestDelta = AdaptiveProbe.binarySearchWithGuess(
                { (delta: UInt64) -> Bool in
                    guard delta > 0 else { return true } // predicate(0) assumed true
                    if let fastMaxDelta, delta > fastMaxDelta {
                        return false
                    }
                    let newBP = searchUpward ? currentBP + delta : currentBP - delta
                    let newChoice = ChoiceValue(
                        choiceTag.makeConvertible(bitPattern64: newBP),
                        tag: choiceTag
                    )
                    guard newChoice.fits(in: validRanges) else { return false }
                    let probeEntry = ChoiceSequenceValue.reduced(.init(choice: newChoice, validRanges: validRanges))
                    guard probeEntry.shortLexCompare(originalEntry) == .lt else {
                        return false
                    }
                    probe[seqIdx] = probeEntry
                    guard
                        rejectCache.contains(probe) == false
                    else {
                        return false
                    }
                    guard let output = try? Interpreters.materialize(gen, with: tree, using: probe) else {
                        rejectCache.insert(probe)
                        return false
                    }
                    let fails = property(output) == false
                    if fails {
                        if delta >= bestProbeDelta {
                            bestProbeDelta = delta
                            bestProbeEntry = probeEntry
                            bestProbeOutput = output
                        }
                    } else {
                        rejectCache.insert(probe)
                    }
                    return fails
                },
                low: UInt64(0),
                high: distance,
                guess: guess
            )

            if bestDelta > 0 {
                if bestProbeDelta == bestDelta, let bestProbeEntry, let bestProbeOutput {
                    current[seqIdx] = bestProbeEntry
                    latestOutput = bestProbeOutput
                    progress = true
                    continue
                }

                // Fallback: reconstruct accepted candidate if probe bookkeeping missed it.
                let newBP = searchUpward ? currentBP + bestDelta : currentBP - bestDelta
                let newChoice = ChoiceValue(
                    choiceTag.makeConvertible(bitPattern64: newBP),
                    tag: choiceTag
                )
                let candidateEntry = ChoiceSequenceValue.reduced(.init(choice: newChoice, validRanges: validRanges))
                var candidate = current
                candidate[seqIdx] = candidateEntry
                if candidateEntry.shortLexCompare(current[seqIdx]) == .lt,
                   let output = try? Interpreters.materialize(gen, with: tree, using: candidate),
                   property(output) == false
                {
                    current = candidate
                    latestOutput = output
                    progress = true
                    continue
                }
            }

            if bestDelta == 0 {
                // No reduction was possible here. Let's try
                // **Local boundary search**: Are there better shrinks just beyond the horizon?
                let offsets = [bestDelta + 1, bestDelta + 2, bestDelta + 4, bestDelta + 8, bestDelta + 16]
                var boundary = current
                for offset in offsets {
                    // Let's make sure we don't under or overflow
                    guard searchUpward ? UInt64.max - offset >= currentBP : currentBP >= offset else {
                        continue
                    }
                    let testBP = searchUpward ? currentBP + offset : currentBP - offset
                    let boundaryChoice = ChoiceValue(
                        choiceTag.makeConvertible(bitPattern64: testBP),
                        tag: choiceTag
                    )
                    guard boundaryChoice.fits(in: validRanges) else { continue }
                    let boundaryEntry = ChoiceSequenceValue.value(.init(choice: boundaryChoice, validRanges: validRanges))
                    guard boundaryEntry.shortLexCompare(current[seqIdx]) == .lt else { continue }
                    boundary[seqIdx] = boundaryEntry

                    if rejectCache.contains(boundary) == false {
                        if let output = try? Interpreters.materialize(gen, with: tree, using: boundary),
                           property(output) == false
                        {
                            latestOutput = output
                            current = boundary
                            progress = true
                            break
                        } else {
                            rejectCache.insert(boundary)
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
}
