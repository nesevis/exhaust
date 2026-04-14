//
//  GraphValueEncoder+Integer.swift
//  Exhaust
//

// MARK: - Integer Mode

extension GraphValueEncoder {
    mutating func startInteger(
        scope: ValueMinimizationScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph,
        warmStarts: [Int: ConvergedOrigin],
        preservingConvergence: [Int: ConvergedOrigin] = [:],
        armBatchZero: Bool = true
    ) {
        var leafPositions: [(nodeID: Int, sequenceIndex: Int, validRange: ClosedRange<UInt64>?, currentBitPattern: UInt64, targetBitPattern: UInt64, typeTag: TypeTag, mayReshape: Bool)] = []

        for entry in scope.leaves {
            let nodeID = entry.nodeID
            // Skip leaves the encoder has already converged in the current
            // pass. Used by ``refreshScope(graph:sequence:)`` to avoid
            // re-driving leaves whose binary search has already finished
            // when the live graph yields a new full scope.
            if preservingConvergence[nodeID] != nil { continue }
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            guard let range = graph.nodes[nodeID].positionRange else { continue }
            let current = metadata.value.bitPattern64
            let target = metadata.value.reductionTarget(in: metadata.validRange)
            if current != target {
                leafPositions.append((
                    nodeID: nodeID,
                    sequenceIndex: range.lowerBound,
                    validRange: metadata.validRange,
                    currentBitPattern: current,
                    targetBitPattern: target,
                    typeTag: metadata.typeTag,
                    mayReshape: entry.mayReshapeOnAcceptance
                ))
            }
        }

        // Phase selection. ``armBatchZero`` is `true` for the initial
        // ``start(scope:)`` call (the trivial all-targets shortcut is
        // worth one probe at pass start) and `false` for refresh calls
        // from ``refreshScope(graph:sequence:)``. Re-arming batch-zero on
        // every refresh wastes one full materialisation per accepted
        // reshape: at refresh time we already know batch-zero was
        // infeasible at pass start (otherwise the per-leaf search wouldn't
        // be running), and the new leaves the splice added rarely flip
        // that. The waste was the dominant cost on BinaryHeap (~30k
        // refresh-induced batchZero probes per 1000-seed run, each
        // rejected because all-zero is a valid heap and the failing
        // predicate requires non-heap shape).
        let initialPhase: IntegerPhase = (armBatchZero && scope.batchZeroEligible) ? .batchZero : .perLeaf

        mode = .valueLeaves(IntegerState(
            sequence: sequence,
            leafPositions: leafPositions,
            phase: initialPhase,
            leafIndex: 0,
            stepper: nil,
            warmStartRecords: warmStarts,
            lastEmittedCandidate: nil,
            batchRejected: false,
            scanValues: nil,
            scanIndex: 0,
            scanBestAccepted: nil,
            crossZero: nil,
            bisection: nil
        ))
    }

    mutating func nextIntegerProbe(
        state: inout IntegerState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        // If the last probe was accepted, update the baseline sequence.
        if lastAccepted, let accepted = state.lastEmittedCandidate {
            state.sequence = accepted
        }
        state.lastEmittedCandidate = nil

        switch state.phase {
        case .batchZero:
            // Try setting all leaves to their targets simultaneously.
            var candidate = state.sequence
            for leaf in state.leafPositions {
                candidate[leaf.sequenceIndex] = candidate[leaf.sequenceIndex]
                    .withBitPattern(leaf.targetBitPattern)
            }
            if candidate.shortLexPrecedes(state.sequence) {
                // Emit the batch-zero probe. If accepted, batchBisect will
                // see lastAccepted=true and converge all leaves. If rejected,
                // batchBisect will begin joint interpolation search.
                if state.leafPositions.count >= 4 {
                    state.phase = .batchBisect
                    state.bisection = BisectionState(
                        pendingGroups: [],
                        activeGroup: (start: 0, end: state.leafPositions.count),
                        divisor: BisectionState.initialDivisor,
                        awaitingFeedback: true,
                        convergedIndices: []
                    )
                } else {
                    state.phase = .perLeaf
                }
                state.lastEmittedCandidate = candidate
                return candidate
            }
            // Batch zero not shortlex-smaller — skip bisection, go to per-leaf.
            state.batchRejected = true
            state.phase = .perLeaf
            return nextIntegerProbe(state: &state, lastAccepted: false)

        case .batchBisect:
            if lastAccepted == false {
                state.batchRejected = true
            }
            return nextBatchBisectProbe(state: &state, lastAccepted: lastAccepted)

        case .perLeaf:
            return nextPerLeafProbe(state: &state, lastAccepted: lastAccepted)
        }
    }

    // MARK: - Batch Bisection

    /// Drives the batch bisection phase: joint interpolation search across leaf groups with bisection on rejection.
    ///
    /// Each group of leaves is searched in tandem — all leaves in the group move one interpolation step toward their targets simultaneously. On acceptance, the group continues stepping (divisor resets). On rejection, the divisor halves; when the divisor reaches the binary threshold and the group has two or more leaves, the group is bisected and each half is searched independently. Single-leaf groups that stall are deferred to the per-leaf phase.
    mutating func nextBatchBisectProbe(
        state: inout IntegerState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        guard var bisection = state.bisection else {
            state.phase = .perLeaf
            return nextPerLeafProbe(state: &state, lastAccepted: false)
        }

        // Handle feedback from the previous probe.
        if bisection.awaitingFeedback, let group = bisection.activeGroup {
            bisection.awaitingFeedback = false
            if lastAccepted {
                // Group made progress — update current bit patterns from the accepted candidate.
                for index in group.start ..< group.end {
                    guard bisection.convergedIndices.contains(index) == false else { continue }
                    let leaf = state.leafPositions[index]
                    // Read the accepted value from the baseline sequence (which was updated by the caller).
                    let acceptedBitPattern = state.sequence[leaf.sequenceIndex].value?.choice.bitPattern64 ?? leaf.currentBitPattern
                    state.leafPositions[index].currentBitPattern = acceptedBitPattern
                    // If the leaf reached its target, mark converged.
                    if acceptedBitPattern == leaf.targetBitPattern {
                        bisection.convergedIndices.insert(index)
                        convergenceStore[leaf.nodeID] = ConvergedOrigin(
                            bound: leaf.targetBitPattern,
                            signal: .monotoneConvergence,
                            configuration: .binarySearchSemanticSimplest,
                            cycle: 0
                        )
                    }
                }
                // Reset divisor for the next step — acceptance confirms the group can move.
                bisection.divisor = BisectionState.initialDivisor
            } else {
                // Group stalled — halve divisor.
                if bisection.divisor > BisectionState.binaryThreshold {
                    bisection.divisor /= 2
                } else {
                    // Divisor exhausted — bisect the group.
                    let groupSize = group.end - group.start
                    if groupSize >= 2 {
                        let mid = group.start + groupSize / 2
                        bisection.pendingGroups.append((start: mid, end: group.end))
                        bisection.pendingGroups.append((start: group.start, end: mid))
                    }
                    // Single leaf: deferred to per-leaf.
                    bisection.activeGroup = nil
                    bisection.divisor = BisectionState.initialDivisor
                }
            }
        }

        // Try to emit a probe for the active group, or pop the next group.
        while true {
            // If no active group, pop the next pending one.
            if bisection.activeGroup == nil {
                guard let nextGroup = bisection.pendingGroups.popLast() else {
                    break
                }
                // Skip single-leaf groups — defer to per-leaf.
                if nextGroup.end - nextGroup.start < 2 {
                    continue
                }
                bisection.activeGroup = nextGroup
                bisection.divisor = BisectionState.initialDivisor
            }

            guard let group = bisection.activeGroup else { break }

            // Check if there are unconverged leaves with room to move.
            let hasWork = (group.start ..< group.end).contains { index in
                bisection.convergedIndices.contains(index) == false
                    && state.leafPositions[index].currentBitPattern != state.leafPositions[index].targetBitPattern
            }
            if hasWork == false {
                bisection.activeGroup = nil
                continue
            }

            // Build candidate: move each unconverged leaf one interpolation step toward its target.
            var candidate = state.sequence
            var anyChanged = false
            for index in group.start ..< group.end {
                guard bisection.convergedIndices.contains(index) == false else { continue }
                let leaf = state.leafPositions[index]
                guard leaf.currentBitPattern != leaf.targetBitPattern else { continue }

                let probeBitPattern: UInt64
                if leaf.currentBitPattern > leaf.targetBitPattern {
                    let range = leaf.currentBitPattern - leaf.targetBitPattern
                    let step = range / bisection.divisor
                    probeBitPattern = step > 0 ? leaf.targetBitPattern + step : leaf.targetBitPattern
                } else {
                    let range = leaf.targetBitPattern - leaf.currentBitPattern
                    let step = range / bisection.divisor
                    probeBitPattern = step > 0 ? leaf.targetBitPattern - step : leaf.targetBitPattern
                }

                if probeBitPattern != leaf.currentBitPattern {
                    candidate[leaf.sequenceIndex] = candidate[leaf.sequenceIndex]
                        .withBitPattern(probeBitPattern)
                    anyChanged = true
                }
            }

            guard anyChanged, candidate.shortLexPrecedes(state.sequence) else {
                // Can't make progress with this group — treat as stall.
                bisection.activeGroup = nil
                continue
            }

            bisection.awaitingFeedback = true
            state.bisection = bisection
            state.lastEmittedCandidate = candidate
            return candidate
        }

        // All groups exhausted — transition to per-leaf phase, skipping converged leaves.
        state.bisection = bisection
        state.phase = .perLeaf
        while state.leafIndex < state.leafPositions.count,
              bisection.convergedIndices.contains(state.leafIndex)
        {
            state.leafIndex += 1
            state.semanticSimplestProbed = false
        }
        return nextPerLeafProbe(state: &state, lastAccepted: false)
    }

    // MARK: - Per-Leaf Orchestrator

    mutating func nextPerLeafProbe(
        state: inout IntegerState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        while state.leafIndex < state.leafPositions.count {
            // Skip leaves already converged by the batch bisection phase.
            if let bisection = state.bisection,
               bisection.convergedIndices.contains(state.leafIndex)
            {
                state.leafIndex += 1
                state.semanticSimplestProbed = false
                continue
            }

            // Cross-zero phase takes priority when active — it was armed by a
            // prior iteration of this loop after binary search converged, and
            // the current `lastAccepted` is feedback for the last cross-zero
            // probe (if any).
            if state.crossZero != nil {
                if let candidate = nextCrossZeroProbe(
                    state: &state,
                    lastAccepted: lastAccepted
                ) {
                    return candidate
                }
                // Cross-zero exhausted or accepted — move to the next leaf.
                state.crossZero = nil
                state.leafIndex += 1
                state.semanticSimplestProbed = false
                continue
            }

            // Linear scan phase (set up by binary search on non-monotone gap).
            if state.scanValues != nil {
                if let candidate = nextLinearScanProbe(
                    state: &state,
                    lastAccepted: lastAccepted
                ) {
                    return candidate
                }
                // Scan exhausted — record convergence, then try cross-zero
                // before advancing to the next leaf. Linear scan probes only
                // `[targetBitPattern, bestAccepted)` which for signed types is one
                // side of zero; cross-zero walks shortlex keys from 0 upward
                // and reaches values on the opposite side that linear scan
                // cannot. They are complementary.
                finishLinearScan(state: &state)
                if tryEnterCrossZero(state: &state) {
                    continue
                }
                state.leafIndex += 1
                state.semanticSimplestProbed = false
                continue
            }

            // Direct shot at the reduction target before binary search. When the property-satisfying subset is sparse in the index space, binary search can settle at a local minimum because non-satisfying gaps cause it to stop early. A single probe at the target guarantees the reduction target is always attempted. One extra materialization per leaf, amortized by the fact that acceptance skips the entire binary search.
            if state.stepper == nil, state.semanticSimplestProbed == false {
                state.semanticSimplestProbed = true
                let leaf = state.leafPositions[state.leafIndex]
                let currentEntry = state.sequence[leaf.sequenceIndex]
                if let currentChoice = currentEntry.value?.choice {
                    let targetBitPattern = leaf.targetBitPattern
                    let currentBitPattern = currentChoice.bitPattern64
                    if currentBitPattern != targetBitPattern {
                        let targetChoice = ChoiceValue(
                            currentChoice.tag.makeConvertible(bitPattern64: targetBitPattern),
                            tag: currentChoice.tag
                        )
                        var candidate = state.sequence
                        let targetEntry = ChoiceSequenceValue.value(.init(
                            choice: targetChoice,
                            validRange: currentEntry.value!.validRange,
                            isRangeExplicit: currentEntry.value!.isRangeExplicit
                        ))
                        candidate[leaf.sequenceIndex] = targetEntry
                        if candidate.shortLexPrecedes(state.sequence) {
                            state.lastEmittedCandidate = candidate
                            return candidate
                        }
                    }
                }
            }

            // Binary search phase.
            if let candidate = nextBitPatternSearchProbe(
                state: &state,
                lastAccepted: lastAccepted
            ) {
                return candidate
            }

            // Binary search converged. If scan was set up, loop back
            // to drain it.
            if state.scanValues != nil {
                continue
            }

            // Try to enter the cross-zero phase for signed types. If
            // successful, the next iteration of this loop will emit the
            // first cross-zero probe with fresh state (no stale feedback).
            if tryEnterCrossZero(state: &state) {
                continue
            }

            state.leafIndex += 1
            state.semanticSimplestProbed = false
        }

        return nil
    }

    // MARK: - Bit-Pattern Binary Search

    /// Drives the per-leaf binary search in bit-pattern space.
    ///
    /// Returns the next candidate, or nil when the stepper converges. On convergence, records the convergence signal and enters the cross-zero phase for signed types.
    mutating func nextBitPatternSearchProbe(
        state: inout IntegerState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        let leaf = state.leafPositions[state.leafIndex]

        if state.stepper == nil {
            // Initialize directional stepper in bit-pattern space.
            let currentEntry = state.sequence[leaf.sequenceIndex]
            guard let currentChoice = currentEntry.value?.choice else {
                return nil
            }
            let currentBitPattern = currentChoice.bitPattern64
            let targetBitPattern = leaf.targetBitPattern

            guard currentBitPattern != targetBitPattern else {
                return nil
            }

            // Warm-start: if a prior cycle converged this leaf with the
            // same encoder configuration, narrow the search bounds to
            // skip the already-explored region. The bound is validated
            // against the current search range — if redistribution moved
            // the leaf past its prior floor, the warm-start is stale and
            // the full range is searched.
            let warmStart = state.warmStartRecords[leaf.nodeID]
            let validWarmStart: ConvergedOrigin? = warmStart.flatMap { ws in
                guard ws.configuration == .binarySearchSemanticSimplest else { return nil }
                if currentBitPattern > targetBitPattern {
                    // Downward search: bound must be in [target, current].
                    return ws.bound >= targetBitPattern && ws.bound <= currentBitPattern ? ws : nil
                } else {
                    // Upward search: bound must be in [current, target].
                    return ws.bound >= currentBitPattern && ws.bound <= targetBitPattern ? ws : nil
                }
            }

            if currentBitPattern > targetBitPattern {
                let effectiveLo = validWarmStart?.bound ?? targetBitPattern
                let range = currentBitPattern - effectiveLo
                if range < InterpolationSearchStepper.binaryThreshold {
                    state.stepper = .downwardBinary(
                        BinarySearchStepper(lo: effectiveLo, hi: currentBitPattern)
                    )
                } else {
                    state.stepper = .downward(
                        InterpolationSearchStepper(lo: effectiveLo, hi: currentBitPattern)
                    )
                }
            } else {
                let effectiveHi = validWarmStart?.bound ?? targetBitPattern
                let range = effectiveHi - currentBitPattern
                if range < MaxInterpolationSearchStepper.binaryThreshold {
                    state.stepper = .upwardBinary(
                        MaxBinarySearchStepper(lo: currentBitPattern, hi: effectiveHi)
                    )
                } else {
                    state.stepper = .upward(
                        MaxInterpolationSearchStepper(lo: currentBitPattern, hi: effectiveHi)
                    )
                }
            }

            guard let firstBitPattern = state.stepper?.start() else {
                state.stepper = nil
                return nil
            }

            var candidate = state.sequence
            candidate[leaf.sequenceIndex] = candidate[leaf.sequenceIndex]
                .withBitPattern(firstBitPattern)
            if candidate.shortLexPrecedes(state.sequence) {
                state.lastEmittedCandidate = candidate
                return candidate
            }
        }

        if let nextBitPattern = state.stepper?.advance(lastAccepted: lastAccepted) {
            var candidate = state.sequence
            candidate[leaf.sequenceIndex] = candidate[leaf.sequenceIndex]
                .withBitPattern(nextBitPattern)
            if candidate.shortLexPrecedes(state.sequence) {
                state.lastEmittedCandidate = candidate
                return candidate
            }
            // Probe not shortlex-smaller — re-enter to advance again.
            return nextBitPatternSearchProbe(
                state: &state,
                lastAccepted: false
            )
        }

        // Stepper converged — check for non-monotone gap.
        if let bestAccepted = state.stepper?.bestAccepted {
            let remaining: UInt64 = bestAccepted > leaf.targetBitPattern
                ? bestAccepted - leaf.targetBitPattern
                : leaf.targetBitPattern - bestAccepted

            if state.batchRejected, bestAccepted == leaf.targetBitPattern {
                // Leaf converged at target but batch-zero failed — zeroing dependency.
                convergenceStore[leaf.nodeID] = ConvergedOrigin(
                    bound: bestAccepted,
                    signal: .zeroingDependency,
                    configuration: .binarySearchSemanticSimplest,
                    cycle: 0
                )
            } else if remaining > 0, remaining <= Self.linearScanThreshold {
                // Non-monotone gap: binary search couldn't reach the target
                // but the gap is small enough to scan exhaustively.
                convergenceStore[leaf.nodeID] = ConvergedOrigin(
                    bound: bestAccepted,
                    signal: .nonMonotoneGap(remainingRange: Int(remaining)),
                    configuration: .binarySearchSemanticSimplest,
                    cycle: 0
                )
                // Set up inline linear scan of [targetBitPattern, bestAccepted).
                let scanLo = min(leaf.targetBitPattern, bestAccepted)
                let scanHi = max(leaf.targetBitPattern, bestAccepted)
                var values: [UInt64] = []
                values.reserveCapacity(Int(remaining))
                var current = scanLo
                while current < scanHi {
                    values.append(current)
                    current += 1
                }
                state.scanValues = values
                state.scanIndex = 0
                state.scanBestAccepted = nil
            } else {
                convergenceStore[leaf.nodeID] = ConvergedOrigin(
                    bound: bestAccepted,
                    signal: .monotoneConvergence,
                    configuration: .binarySearchSemanticSimplest,
                    cycle: 0
                )
            }
        }
        state.stepper = nil
        return nil
    }

    // MARK: - Linear Scan Recovery

    /// Scans values in the non-monotone gap to find a lower floor than binary search achieved.
    mutating func nextLinearScanProbe(
        state: inout IntegerState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        let leaf = state.leafPositions[state.leafIndex]

        // Track acceptance of previous scan probe.
        if lastAccepted, state.scanIndex > 0 {
            let acceptedValue = state.scanValues![state.scanIndex - 1]
            if state.scanBestAccepted == nil || acceptedValue < state.scanBestAccepted! {
                state.scanBestAccepted = acceptedValue
            }
        }

        guard let scanValues = state.scanValues else { return nil }
        guard state.scanIndex < scanValues.count else { return nil }

        let probeValue = scanValues[state.scanIndex]
        state.scanIndex += 1

        var candidate = state.sequence
        candidate[leaf.sequenceIndex] = candidate[leaf.sequenceIndex]
            .withBitPattern(probeValue)

        guard candidate.shortLexPrecedes(state.sequence) else {
            // Value doesn't improve shortlex — skip to next.
            return nextLinearScanProbe(state: &state, lastAccepted: false)
        }

        state.lastEmittedCandidate = candidate
        return candidate
    }

    /// Records the final convergence from a completed linear scan.
    mutating func finishLinearScan(state: inout IntegerState) {
        let leaf = state.leafPositions[state.leafIndex]
        let foundLowerFloor = state.scanBestAccepted != nil
        let bound = state.scanBestAccepted
            ?? convergenceStore[leaf.nodeID]?.bound
            ?? leaf.targetBitPattern
        convergenceStore[leaf.nodeID] = ConvergedOrigin(
            bound: bound,
            signal: .scanComplete(foundLowerFloor: foundLowerFloor),
            configuration: .linearScan,
            cycle: 0
        )
        state.scanValues = nil
        state.scanIndex = 0
        state.scanBestAccepted = nil
    }

    // MARK: - Cross-Zero Phase

    /// Attempts to arm the cross-zero phase for the current leaf.
    ///
    /// Returns `true` when the leaf is a signed type with a current shortlex key > 0 (there is at least one strictly simpler value to try). On success, ``IntegerState/crossZero`` is set and the per-leaf dispatch loop will emit the first probe on its next iteration.
    ///
    /// The probe budget adapts to the current shortlex key: roughly `log₂(key) + 4`, clamped to `[4, 16]`. Rationale: bit-pattern binary search has already covered the large-magnitude neighborhood by the time cross-zero runs, so cross-zero's contribution is bounded to the last few shortlex keys near zero. Small-magnitude leaves get full coverage of every key below their current one; large-magnitude leaves get the simplest 16 keys. A fixed 16-probe cap is a special case of this at the upper end of the range.
    mutating func tryEnterCrossZero(state: inout IntegerState) -> Bool {
        let leaf = state.leafPositions[state.leafIndex]
        guard leaf.typeTag.isSigned else { return false }
        guard let currentEntry = state.sequence[leaf.sequenceIndex].value else {
            return false
        }
        let currentKey = currentEntry.choice.shortlexKey
        guard currentKey > 0 else { return false }

        // Micro-opt 1: skip cross-zero when `value(0)` is outside an explicit
        // valid range. Every cross-zero probe walks shortlex keys near zero,
        // and if zero itself is out of range the walk's near neighbors are
        // almost certainly out too — the materializer will reject every probe
        // we emit. For generators like `int(in: 1...1000)` this saves the full
        // budget of wasted probes per leaf.
        //
        // The zero bit pattern is computed via `semanticSimplest.bitPattern64`
        // rather than `makeConvertible(bitPattern64: 0)`: for signed types the
        // XOR sign-magnitude encoding maps bit pattern 0 to the most negative
        // value, so `makeConvertible(bitPattern64: 0)` would return `Int.min`,
        // not semantic zero.
        if currentEntry.isRangeExplicit, let range = currentEntry.validRange {
            let zeroBitPattern = currentEntry.choice.semanticSimplest.bitPattern64
            if range.contains(zeroBitPattern) == false {
                return false
            }
            // Micro-opt 2: skip cross-zero when the leaf's current value pins
            // the valid range's boundary. Binary search has already exhausted
            // everything between the boundary and the reduction target; the
            // remaining "simpler" candidates cross-zero would try are all in
            // that already-rejected region. The property has demonstrated
            // that this exact boundary value is required. Saves the full
            // budget of wasted probes per pinned leaf (for example, Bound5's
            // leaves at `Int16.min`).
            let currentBitPattern = currentEntry.choice.bitPattern64
            if currentBitPattern == range.lowerBound || currentBitPattern == range.upperBound {
                return false
            }
        }

        // Adaptive budget: ⌈log₂(currentKey + 1)⌉ + 4, clamped to [4, 16].
        // Small keys get one probe per key below them (fully exhaustive),
        // large keys get the simplest 16 shortlex keys (0..15).
        let bitLength = UInt64(64 - currentKey.leadingZeroBitCount)
        let budget = min(bitLength + 4, 16)
        let endKey = min(currentKey, budget)

        state.crossZero = CrossZeroState(
            seqIdx: leaf.sequenceIndex,
            tag: leaf.typeTag,
            validRange: currentEntry.validRange,
            isRangeExplicit: currentEntry.isRangeExplicit,
            nextKey: 0,
            endKey: endKey,
            lastEmittedKey: nil
        )
        return true
    }

    /// Drives the cross-zero phase for the current leaf.
    ///
    /// Walks shortlex keys from 0 upward, emitting one candidate per call and exiting on the first acceptance — walking upward guarantees that the first accepted probe is the simplest possible value for this leaf, so there is no benefit to continuing once one is found.
    ///
    /// Returns `nil` when the walk is exhausted (all probes rejected or budget reached) or when the caller should advance to the next leaf (acceptance happened on the prior call). The caller clears ``IntegerState/crossZero`` and advances `leafIndex` when `nil` is returned.
    mutating func nextCrossZeroProbe(
        state: inout IntegerState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        guard var crossZero = state.crossZero else { return nil }

        // Consume feedback for the previous probe, if any.
        if let acceptedKey = crossZero.lastEmittedKey {
            crossZero.lastEmittedKey = nil
            if lastAccepted {
                // Acceptance — nextIntegerProbe has already advanced
                // state.sequence to the accepted candidate. Record the
                // convergence at the new bit pattern so the next cycle's
                // binary search can warm-start from here, then exit.
                let leaf = state.leafPositions[state.leafIndex]
                let acceptedChoice = ChoiceValue.fromShortlexKey(
                    acceptedKey,
                    tag: crossZero.tag
                )
                convergenceStore[leaf.nodeID] = ConvergedOrigin(
                    bound: acceptedChoice.bitPattern64,
                    signal: .monotoneConvergence,
                    configuration: .binarySearchSemanticSimplest,
                    cycle: 0
                )
                state.crossZero = crossZero
                return nil
            }
            // Rejection — fall through and emit the next probe.
        }

        // Walk upward from `nextKey` looking for a probe that is in range.
        while crossZero.nextKey < crossZero.endKey {
            let probeKey = crossZero.nextKey
            crossZero.nextKey += 1

            let probeChoice = ChoiceValue.fromShortlexKey(probeKey, tag: crossZero.tag)

            // Range validation: when the range is explicitly user-declared,
            // a probe outside it would be rejected by the materializer.
            // Skip rather than waste a property call.
            if crossZero.isRangeExplicit,
               probeChoice.fits(in: crossZero.validRange) == false
            {
                continue
            }

            crossZero.lastEmittedKey = probeKey
            state.crossZero = crossZero

            var candidate = state.sequence
            candidate[crossZero.seqIdx] = .reduced(.init(
                choice: probeChoice,
                validRange: crossZero.validRange,
                isRangeExplicit: crossZero.isRangeExplicit
            ))
            state.lastEmittedCandidate = candidate
            return candidate
        }

        // Exhausted — no further probes to try.
        state.crossZero = crossZero
        return nil
    }
}
