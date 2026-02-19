//
//  ReducerStrategies+ReduceValues.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/2/2026.
//

extension ReducerStrategies {
    /// Binary search each individual value toward its reduction target.
    /// For each `.value` entry, computes an initial target from recorded valid ranges,
    /// then binary searches between the current bit pattern and that target to find the
    /// minimum failing value.
    ///
    /// If recorded ranges appear to block progress, the pass may probe one step beyond
    /// the recorded boundary so subsequent loops can continue shrinking with refreshed context.
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
        rejectCache: inout ReducerCache,
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
            let semanticTargetBP = v.choice.semanticSimplest.bitPattern64
            let isWithinRecordedRange = v.choice.fits(in: validRanges)
            let targetBP = isWithinRecordedRange
                ? v.choice.reductionTarget(in: validRanges)
                : semanticTargetBP
            let currentEntry = current[seqIdx]

            if currentBP == targetBP {
                // Already at recorded-range target. If semantic target lies outside that range,
                // probe one step past the recorded boundary to unlock further shrinking.
                if isWithinRecordedRange, semanticTargetBP != targetBP {
                    _ = tryUnlockBoundary(
                        .init(
                            seqIdx: seqIdx,
                            choiceTag: choiceTag,
                            currentEntry: currentEntry,
                            currentBP: currentBP,
                            targetBP: targetBP,
                            semanticTargetBP: semanticTargetBP,
                            validRanges: validRanges,
                        ),
                        gen: gen,
                        tree: tree,
                        property: property,
                        currentSequence: &current,
                        latestOutput: &latestOutput,
                        progress: &progress,
                        rejectCache: &rejectCache,
                    )
                }
                continue
            }

            let searchUpward = targetBP > currentBP
            let distance = searchUpward
                ? targetBP - currentBP
                : currentBP - targetBP
            let fastMaxDelta: UInt64? = {
                guard isWithinRecordedRange,
                      validRanges.count == 1,
                      let containingRange = validRanges.first(where: { $0.contains(currentBP) })
                else {
                    return nil
                }
                return searchUpward
                    ? (containingRange.upperBound - currentBP)
                    : (currentBP - containingRange.lowerBound)
            }()

            // Try target directly
            let targetChoice = ChoiceValue(
                choiceTag.makeConvertible(bitPattern64: targetBP),
                tag: choiceTag,
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
            if distance <= 1 {
                if isWithinRecordedRange, semanticTargetBP != targetBP {
                    _ = tryUnlockBoundary(
                        .init(
                            seqIdx: seqIdx,
                            choiceTag: choiceTag,
                            currentEntry: currentEntry,
                            currentBP: currentBP,
                            targetBP: targetBP,
                            semanticTargetBP: semanticTargetBP,
                            validRanges: validRanges,
                        ),
                        gen: gen,
                        tree: tree,
                        property: property,
                        currentSequence: &current,
                        latestOutput: &latestOutput,
                        progress: &progress,
                        rejectCache: &rejectCache,
                    )
                }
                continue
            }
            let originalEntry = current[seqIdx]
            var probe = current
            var bestProbeEntry: ChoiceSequenceValue?
            var bestProbeOutput: Output?
            var bestProbeDelta: UInt64 = 0

            let bestDelta = AdaptiveProbe.binarySearchWithGuess(
                { (delta: UInt64) -> Bool in
                    guard delta > 0 else { return true } // predicate(0) assumed true
                    if let fastMaxDelta, delta > fastMaxDelta {
                        return false
                    }
                    guard searchUpward ? UInt64.max - delta >= currentBP : currentBP >= delta else {
                        return false
                    }
                    let newBP = searchUpward ? currentBP + delta : currentBP - delta
                    let newChoice = ChoiceValue(
                        choiceTag.makeConvertible(bitPattern64: newBP),
                        tag: choiceTag,
                    )
                    if isWithinRecordedRange, newChoice.fits(in: validRanges) == false {
                        return false
                    }
                    let probeEntry = ChoiceSequenceValue.reduced(.init(choice: newChoice, validRanges: validRanges))
                    guard probeEntry.shortLexCompare(originalEntry) == .lt else {
                        return false
                    }
                    probe[seqIdx] = probeEntry
                    guard rejectCache.contains(probe) == false
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
                    tag: choiceTag,
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
                var boundaryImproved = false
                for offset in offsets {
                    // Let's make sure we don't under or overflow
                    guard searchUpward ? UInt64.max - offset >= currentBP : currentBP >= offset else {
                        continue
                    }
                    let testBP = searchUpward ? currentBP + offset : currentBP - offset
                    let boundaryChoice = ChoiceValue(
                        choiceTag.makeConvertible(bitPattern64: testBP),
                        tag: choiceTag,
                    )
                    if isWithinRecordedRange, boundaryChoice.fits(in: validRanges) == false {
                        continue
                    }
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
                            boundaryImproved = true
                            break
                        } else {
                            rejectCache.insert(boundary)
                        }
                    }
                }
                if boundaryImproved {
                    continue
                }

                // Escape hatch: if recorded bounds blocked progress, probe one step past
                // that boundary so subsequent loops can continue shrinking from there.
                if isWithinRecordedRange, semanticTargetBP != targetBP {
                    if tryUnlockBoundary(
                        .init(
                            seqIdx: seqIdx,
                            choiceTag: choiceTag,
                            currentEntry: currentEntry,
                            currentBP: currentBP,
                            targetBP: targetBP,
                            semanticTargetBP: semanticTargetBP,
                            validRanges: validRanges,
                        ),
                        gen: gen,
                        tree: tree,
                        property: property,
                        currentSequence: &current,
                        latestOutput: &latestOutput,
                        progress: &progress,
                        rejectCache: &rejectCache,
                    ) {
                        continue
                    }
                }
            }
        }

        if progress, let output = latestOutput {
            return (current, output)
        }
        return nil
    }

    /// Probes exactly one bit-pattern step past a recorded boundary when `reduceValues` appears range-locked.
    ///
    /// Motivation:
    /// `ChoiceSequenceValue.Value.validRanges` are recorded from the tree *at the time the value was
    /// generated*. During reduction, earlier successful edits can change parent decisions (especially
    /// through `bind` and branch pivots), which in turn changes the runtime-valid range for descendants.
    /// The recorded range can then be stale.
    ///
    /// Why this matters:
    /// `reduceValues` uses recorded ranges as a fast heuristic to bound binary search. Without an
    /// escape hatch, a descendant can become stuck at a stale lower bound forever, even though replay
    /// accepts smaller values under the new parent context.
    ///
    /// Concrete examples:
    /// 1. Binary-heap shrink:
    /// A node value drops from `91` to `0`, but grandchildren still carry recorded ranges `91...100`.
    /// Range-gated search cannot move below `91`, so shrinking stalls. Probing `90` succeeds under the
    /// updated parent, and subsequent loops continue to `0`, yielding the expected minimal counterexample.
    /// 2. Bind-dependent generator:
    /// `Gen.choose(0...100).bind { p in Gen.choose(p...100) }`.
    /// After `p` shrinks, children may still have metadata from the old `p`. Recorded-range search can
    /// reject candidates that replay now accepts. One-step unlock re-enters a valid shrinking path.
    ///
    /// Why only one step:
    /// We deliberately avoid globally disabling range guidance. A one-step probe keeps oracle cost low,
    /// preserves the fast path for well-formed metadata, and only activates when pass 5 has no in-range
    /// improvement left.
    ///
    /// - Returns: `true` if the unlock candidate was accepted and `currentSequence` was updated.
    private static func tryUnlockBoundary<Output>(
        _ input: UnlockProbeInput,
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        currentSequence: inout ChoiceSequence,
        latestOutput: inout Output?,
        progress: inout Bool,
        rejectCache: inout ReducerCache,
    ) -> Bool {
        guard input.semanticTargetBP != input.targetBP else { return false }
        let unlockBP: UInt64? = if input.semanticTargetBP < input.targetBP {
            input.targetBP > 0 ? input.targetBP - 1 : nil
        } else if input.semanticTargetBP > input.targetBP {
            input.targetBP < UInt64.max ? input.targetBP + 1 : nil
        } else {
            nil
        }

        guard let unlockBP,
              unlockBP != input.currentBP
        else {
            return false
        }

        let unlockChoice = ChoiceValue(
            input.choiceTag.makeConvertible(bitPattern64: unlockBP),
            tag: input.choiceTag,
        )
        let unlockEntry = ChoiceSequenceValue.reduced(.init(choice: unlockChoice, validRanges: input.validRanges))
        var unlockCandidate = currentSequence
        unlockCandidate[input.seqIdx] = unlockEntry
        guard unlockEntry.shortLexCompare(input.currentEntry) == .lt,
              rejectCache.contains(unlockCandidate) == false
        else {
            return false
        }

        if let output = try? Interpreters.materialize(gen, with: tree, using: unlockCandidate),
           property(output) == false
        {
            currentSequence = unlockCandidate
            latestOutput = output
            progress = true
            return true
        }

        rejectCache.insert(unlockCandidate)
        return false
    }
}
