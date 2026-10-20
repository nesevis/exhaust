//
//  IntegerSearch+Probing.swift
//  Exhaust
//

// MARK: - Phases

extension IntegerSearch {
    /// Collects the scope's integer leaves that are not yet at their targets, starting in batch zero when the scope allows it and in per-leaf search otherwise.
    static func initialState(
        scope: ValueMinimizationScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph,
        warmStarts: [Int: ConvergedOrigin],
        tuning: ReductionTuning
    ) -> State {
        var leafPositions: [LeafPosition] = []

        for entry in scope.leaves {
            let nodeID = entry.nodeID
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else {
                continue
            }
            guard let range = graph.nodes[nodeID].positionRange else {
                continue
            }
            let current = metadata.value.bitPattern64
            let target = metadata.value.reductionTarget(in: metadata.validRange)
            if current != target {
                leafPositions.append(LeafPosition(
                    nodeID: nodeID,
                    sequenceIndex: range.lowerBound,
                    currentBitPattern: current,
                    targetBitPattern: target,
                    typeTag: metadata.typeTag,
                    mayReshape: entry.mayReshapeOnAcceptance,
                    characterSimplifications: metadata.characterSimplifications
                ))
            }
        }

        // The all-targets shortcut is worth one probe at the start of a search.
        let initialPhase: Phase = scope.batchZeroEligible ? .batchZero : .perLeaf

        return State(
            linearScanThreshold: tuning.valueLinearScanThreshold,
            bisectionInitialDivisor: tuning.valueBisectionInitialDivisor,
            bisectionBinaryThreshold: tuning.valueBisectionBinaryThreshold,
            interpolationBinaryThreshold: tuning.interpolationBinaryThreshold,
            interpolationInitialDivisor: tuning.interpolationInitialDivisor,
            sequence: sequence,
            leafPositions: leafPositions,
            phase: initialPhase,
            leafIndex: 0,
            stepper: nil,
            warmStartRecords: warmStarts,
            batchRejected: false,
            candidateList: nil,
            crossZero: nil,
            bisection: nil
        )
    }

    /// Advances through the integer phase state machine (batch-zero, per-leaf-zero, batch bisection, per-leaf), returning the next candidate ``ChoiceSequence`` to probe or nil when all phases are exhausted. The caller has already made an accepted candidate the baseline, so subsequent probes build on it.
    static func nextProbe(
        state: inout State,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        switch state.phase {
            case .batchZero:
                // Try every leaf at its target at once.
                var candidate = state.sequence
                for leaf in state.leafPositions {
                    candidate[leaf.sequenceIndex] = candidate[leaf.sequenceIndex]
                        .withBitPattern(leaf.targetBitPattern)
                }
                if candidate.shortLexPrecedes(state.sequence) {
                    // If the batch-zero probe is accepted, per-leaf zero sees the acceptance and converges every leaf. If it is rejected, per-leaf zero tries each leaf at its target alone.
                    state.phase = .perLeafZero
                    state.perLeafZero = PerLeafZeroState()
                    return candidate
                }
                // Batch zero does not precede the sequence, so skip to per-leaf search.
                state.batchRejected = true
                state.phase = .perLeaf
                return nextProbe(state: &state, lastAccepted: false)

            case .perLeafZero:
                return nextPerLeafZeroProbe(state: &state, lastAccepted: lastAccepted)

            case .batchBisect:
                if lastAccepted == false {
                    state.batchRejected = true
                }
                return nextBatchBisectProbe(state: &state, lastAccepted: lastAccepted)

            case .perLeaf:
                return nextPerLeafProbe(state: &state, lastAccepted: lastAccepted)
        }
    }

    // MARK: - Per-Leaf Zero Pre-Round

    /// Tries each leaf individually at its reduction target. Leaves that accept converge immediately and are excluded from batch bisection. After all leaves are tried, transitions to batch bisection with only the survivors.
    static func nextPerLeafZeroProbe(
        state: inout State,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        guard var perLeafZero = state.perLeafZero else {
            state.phase = .perLeaf
            return nextProbe(state: &state, lastAccepted: lastAccepted)
        }

        // Process feedback from the previous per-leaf-zero probe.
        if lastAccepted {
            guard perLeafZero.leafCursor > 0 else {
                // Batch zero was accepted, so every leaf is at its target.
                state.perLeafZero = nil
                state.phase = .perLeaf
                return nil
            }
            // The leaf before the cursor was accepted at its target.
            let acceptedIndex = perLeafZero.leafCursor - 1
            perLeafZero.convergedIndices.insert(acceptedIndex)
            state.leafPositions[acceptedIndex].currentBitPattern = state.leafPositions[acceptedIndex].targetBitPattern
        }

        // Try the next unconverged leaf.
        while perLeafZero.leafCursor < state.leafPositions.count {
            let index = perLeafZero.leafCursor
            perLeafZero.leafCursor += 1
            let leaf = state.leafPositions[index]
            guard leaf.currentBitPattern != leaf.targetBitPattern else {
                perLeafZero.convergedIndices.insert(index)
                continue
            }

            var candidate = state.sequence
            candidate[leaf.sequenceIndex] = candidate[leaf.sequenceIndex]
                .withBitPattern(leaf.targetBitPattern)

            guard candidate.shortLexPrecedes(state.sequence) else {
                continue
            }

            state.perLeafZero = perLeafZero
            return candidate
        }

        // All leaves tried. Batch bisection runs on the survivors only when at least four remain.
        let unconvergedCount = state.leafPositions.count - perLeafZero.convergedIndices.count
        state.perLeafZero = nil
        state.batchRejected = true

        // TODO: Document or tune the four-leaf threshold for batch bisection.
        if unconvergedCount >= 4 {
            state.phase = .batchBisect
            state.bisection = BisectionState(
                pendingGroups: [],
                activeGroup: (start: 0, end: state.leafPositions.count),
                divisor: state.bisectionInitialDivisor,
                awaitingFeedback: false,
                convergedIndices: perLeafZero.convergedIndices
            )
            return nextProbe(state: &state, lastAccepted: false)
        }

        state.phase = .perLeaf
        return nextProbe(state: &state, lastAccepted: false)
    }

    // MARK: - Batch Bisection

    /// Drives the batch bisection phase: joint interpolation search across leaf groups with bisection on rejection.
    ///
    /// Each probe moves every unconverged leaf in the group to `1 / divisor` of its remaining distance from its target. An acceptance resets the divisor and the group keeps stepping. A rejection halves the divisor; once the divisor reaches the binary threshold, a group of two or more leaves splits into halves searched independently. Single-leaf groups are left to the per-leaf phase.
    static func nextBatchBisectProbe(
        state: inout State,
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
                // The group moved: read each leaf's accepted bit pattern from the baseline, which the caller has already advanced.
                for index in group.start ..< group.end {
                    guard bisection.convergedIndices.contains(index) == false else {
                        continue
                    }
                    let leaf = state.leafPositions[index]
                    let acceptedBitPattern = state.sequence[leaf.sequenceIndex].value?.choice.bitPattern64 ?? leaf.currentBitPattern
                    state.leafPositions[index].currentBitPattern = acceptedBitPattern
                    if acceptedBitPattern == leaf.targetBitPattern {
                        bisection.convergedIndices.insert(index)
                        state.convergenceStore[leaf.nodeID] = ConvergedOrigin(
                            bound: leaf.targetBitPattern,
                            signal: .monotoneConvergence,
                            configuration: .binarySearchSemanticSimplest,
                            cycle: 0
                        )
                    }
                }
                // The group can move, so the next step starts from the initial divisor again.
                bisection.divisor = state.bisectionInitialDivisor
            } else {
                // The group stalled, so the next step is smaller.
                if bisection.divisor > state.bisectionBinaryThreshold {
                    bisection.divisor /= 2
                } else {
                    // Divisor exhausted: bisect the group.
                    let groupSize = group.end - group.start
                    if groupSize >= 2 {
                        let midpoint = group.start + groupSize / 2
                        bisection.pendingGroups.append((start: midpoint, end: group.end))
                        bisection.pendingGroups.append((start: group.start, end: midpoint))
                    }
                    // A single leaf is left to the per-leaf phase.
                    bisection.activeGroup = nil
                    bisection.divisor = state.bisectionInitialDivisor
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
                // Single-leaf groups are left to the per-leaf phase.
                if nextGroup.end - nextGroup.start < 2 {
                    continue
                }
                bisection.activeGroup = nextGroup
                bisection.divisor = state.bisectionInitialDivisor
            }

            guard let group = bisection.activeGroup else {
                break
            }

            let hasWork = (group.start ..< group.end).contains { index in
                bisection.convergedIndices.contains(index) == false
                    && state.leafPositions[index].currentBitPattern != state.leafPositions[index].targetBitPattern
            }
            if hasWork == false {
                bisection.activeGroup = nil
                continue
            }

            // Move each unconverged leaf to `1 / divisor` of its distance from its target.
            var candidate = state.sequence
            var anyChanged = false
            for index in group.start ..< group.end {
                guard bisection.convergedIndices.contains(index) == false else {
                    continue
                }
                let leaf = state.leafPositions[index]
                guard leaf.currentBitPattern != leaf.targetBitPattern else {
                    continue
                }

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
                // The group cannot move, which counts as a stall.
                bisection.activeGroup = nil
                continue
            }

            bisection.awaitingFeedback = true
            state.bisection = bisection
            return candidate
        }

        // All groups exhausted: continue with per-leaf search, skipping converged leaves.
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

    /// Searches each leaf in sequence order: a direct shot at the reduction target, then bit-pattern search, then a candidate list when one was set up (a linear scan over a non-monotone gap, or simpler forms of a character), and finally the cross-zero phase for signed types. Returns nil when every leaf is done.
    static func nextPerLeafProbe(
        state: inout State,
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

            // An active cross-zero phase goes first: an earlier iteration armed it after binary search converged, so `lastAccepted` is feedback for its last probe, if any.
            if state.crossZero != nil {
                if let candidate = nextCrossZeroProbe(
                    state: &state,
                    lastAccepted: lastAccepted
                ) {
                    return candidate
                }
                // Cross-zero exhausted or accepted: move to the next leaf.
                state.crossZero = nil
                state.leafIndex += 1
                state.semanticSimplestProbed = false
                continue
            }

            // A candidate list, set up when binary search converged on a non-monotone gap or a character leaf.
            if let source = state.candidateList?.source {
                if let candidate = nextCandidateListProbe(
                    state: &state,
                    lastAccepted: lastAccepted
                ) {
                    return candidate
                }
                finishCandidateList(state: &state)
                // A gap scan probes only `[targetBitPattern, bestAccepted)`, which for a signed type is one side of zero. Cross-zero walks shortlex keys up from zero and reaches the other side.
                if source == .gapScan, tryEnterCrossZero(state: &state) {
                    continue
                }
                state.leafIndex += 1
                state.semanticSimplestProbed = false
                continue
            }

            // Probe the target before binary search. When failing values are sparse, binary search can stop at a local minimum short of the target. The probe costs one materialization per leaf, and an acceptance skips the binary search entirely.
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

            // Binary search converged. Loop back to drain a candidate list if one was set up.
            if state.candidateList != nil {
                continue
            }

            // Arm cross-zero for a signed leaf. The next iteration emits its first probe with no stale feedback.
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
    /// Returns the next candidate, or nil when the stepper converges. On convergence, records the leaf's convergence and sets up a candidate list for a small non-monotone gap or a character leaf. The caller arms cross-zero.
    static func nextBitPatternSearchProbe(
        state: inout State,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        let leaf = state.leafPositions[state.leafIndex]
        let currentEntry = state.sequence[leaf.sequenceIndex]

        if state.stepper == nil {
            guard let currentChoice = currentEntry.value?.choice else {
                return nil
            }
            let currentBitPattern = currentChoice.bitPattern64
            let targetBitPattern = leaf.targetBitPattern

            guard currentBitPattern != targetBitPattern else {
                return nil
            }

            // A record from an earlier pass with the same configuration narrows the search to the region not yet explored. A bound outside the current range is stale, for example after redistribution moved the leaf past its old floor, and the full range is searched instead.
            let warmStart = state.warmStartRecords[leaf.nodeID]
            let validWarmStart: ConvergedOrigin? = warmStart.flatMap { record in
                guard record.configuration == .binarySearchSemanticSimplest else {
                    return nil
                }
                if currentBitPattern > targetBitPattern {
                    return record.bound >= targetBitPattern && record.bound <= currentBitPattern ? record : nil
                } else {
                    return record.bound >= currentBitPattern && record.bound <= targetBitPattern ? record : nil
                }
            }

            if currentBitPattern > targetBitPattern {
                let effectiveLo = validWarmStart?.bound ?? targetBitPattern
                let range = currentBitPattern - effectiveLo
                if range < state.interpolationBinaryThreshold {
                    state.stepper = DirectionalStepper(
                        binary: BinarySearchStepper(lo: effectiveLo, hi: currentBitPattern)
                    )
                } else {
                    state.stepper = DirectionalStepper(
                        interpolation: InterpolationSearchStepper(
                            lo: effectiveLo,
                            hi: currentBitPattern,
                            binaryThreshold: state.interpolationBinaryThreshold,
                            initialDivisor: state.interpolationInitialDivisor
                        )
                    )
                }
            } else {
                let effectiveHi = validWarmStart?.bound ?? targetBitPattern
                let range = effectiveHi - currentBitPattern
                if range < state.interpolationBinaryThreshold {
                    state.stepper = DirectionalStepper(
                        binary: BinarySearchStepper(lo: currentBitPattern, hi: effectiveHi, direction: .findLargest)
                    )
                } else {
                    state.stepper = DirectionalStepper(
                        interpolation: InterpolationSearchStepper(
                            lo: currentBitPattern,
                            hi: effectiveHi,
                            direction: .findLargest,
                            binaryThreshold: state.interpolationBinaryThreshold,
                            initialDivisor: state.interpolationInitialDivisor
                        )
                    )
                }
            }

            guard let firstBitPattern = state.stepper?.start() else {
                state.stepper = nil
                return nil
            }

            let newEntry = currentEntry.withBitPattern(firstBitPattern)
            if newEntry.shortLexCompare(currentEntry) == .lt {
                var candidate = state.sequence
                candidate[leaf.sequenceIndex] = newEntry
                return candidate
            }
        }

        var accepted = lastAccepted
        while let nextBitPattern = state.stepper?.advance(lastAccepted: accepted) {
            let newEntry = currentEntry.withBitPattern(nextBitPattern)
            if newEntry.shortLexCompare(currentEntry) == .lt {
                var candidate = state.sequence
                candidate[leaf.sequenceIndex] = newEntry
                return candidate
            }
            accepted = false
        }

        // Stepper converged: record how, and look for a non-monotone gap.
        if let bestAccepted = state.stepper?.bestAccepted {
            let remaining: UInt64 = bestAccepted.absoluteDifference(leaf.targetBitPattern)

            if state.batchRejected, bestAccepted == leaf.targetBitPattern {
                // The leaf reaches its target alone but batch zero failed, so it depends on other leaves staying put.
                state.convergenceStore[leaf.nodeID] = ConvergedOrigin(
                    bound: bestAccepted,
                    signal: .zeroingDependency,
                    configuration: .binarySearchSemanticSimplest,
                    cycle: 0
                )
            } else if remaining > 0, remaining <= state.linearScanThreshold {
                // Binary search stopped short of the target, but the gap is small enough to scan exhaustively.
                state.convergenceStore[leaf.nodeID] = ConvergedOrigin(
                    bound: bestAccepted,
                    signal: .nonMonotoneGap(remainingRange: Int(remaining)),
                    configuration: .binarySearchSemanticSimplest,
                    cycle: 0
                )
                let scanLo = min(leaf.targetBitPattern, bestAccepted)
                let scanHi = max(leaf.targetBitPattern, bestAccepted)
                state.candidateList = CandidateListState(
                    source: .gapScan,
                    candidates: ArraySlice(scanLo ..< scanHi)
                )
            } else {
                state.convergenceStore[leaf.nodeID] = ConvergedOrigin(
                    bound: bestAccepted,
                    signal: .monotoneConvergence,
                    configuration: .binarySearchSemanticSimplest,
                    cycle: 0
                )
            }
        }
        // A linear scan already covers every index below the converged value, so simplification candidates are only needed without one.
        if state.candidateList == nil,
           let simplifications = leaf.characterSimplifications,
           let currentBitPattern = state.sequence[leaf.sequenceIndex].value?.choice.bitPattern64
        {
            let candidates = simplifications.simplerIndices(than: currentBitPattern)
            if candidates.isEmpty == false {
                state.candidateList = CandidateListState(
                    source: .characterSimplification,
                    candidates: candidates
                )
            }
        }
        state.stepper = nil
        return nil
    }

    // MARK: - Candidate List

    /// Probes the current leaf's candidate list in ascending order, skipping candidates that do not shortlex-precede the current entry.
    ///
    /// Returns nil when the list is exhausted, or after the first acceptance when ``CandidateListSource/endsOnFirstAcceptance`` holds.
    static func nextCandidateListProbe(
        state: inout State,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        guard var list = state.candidateList else {
            return nil
        }
        let leaf = state.leafPositions[state.leafIndex]

        if lastAccepted, list.recordOutstandingAcceptance() {
            if list.source.endsOnFirstAcceptance {
                state.candidateList = list
                return nil
            }
        }

        let currentEntry = state.sequence[leaf.sequenceIndex]
        while list.nextIndex < list.candidates.endIndex {
            let probeValue = list.candidates[list.nextIndex]
            list.nextIndex += 1
            let newEntry = currentEntry.withBitPattern(probeValue)
            guard newEntry.shortLexCompare(currentEntry) == .lt else {
                continue
            }
            var candidate = state.sequence
            candidate[leaf.sequenceIndex] = newEntry
            state.candidateList = list
            return candidate
        }
        state.candidateList = list
        return nil
    }

    /// Records the convergence of a finished candidate list and clears it.
    static func finishCandidateList(state: inout State) {
        guard let list = state.candidateList else {
            return
        }
        state.candidateList = nil
        let leaf = state.leafPositions[state.leafIndex]
        switch list.source {
            case .gapScan:
                let bound = list.bestAccepted
                    ?? state.convergenceStore[leaf.nodeID]?.bound
                    ?? leaf.targetBitPattern
                state.convergenceStore[leaf.nodeID] = ConvergedOrigin(
                    bound: bound,
                    signal: .scanComplete(foundLowerFloor: list.bestAccepted != nil),
                    configuration: .linearScan,
                    cycle: 0
                )
            case .characterSimplification:
                guard let bestAccepted = list.bestAccepted else {
                    return
                }
                state.lowerRecordedBound(to: bestAccepted, nodeID: leaf.nodeID)
        }
    }

    // MARK: - Cross-Zero Phase

    /// Attempts to arm the cross-zero phase for the current leaf.
    ///
    /// Returns `true` when the leaf is signed and its shortlex key is above zero, so a simpler value exists. ``State/crossZero`` is then set, and the per-leaf loop emits the first probe on its next iteration.
    ///
    /// The walk covers at most `⌈log₂(key + 1)⌉ + 4` keys, capped at 16. Bit-pattern search has already covered large magnitudes on the current side of zero, so cross-zero only needs the keys nearest zero: a small key gets every key below it, a large key the simplest 16. A negative value's positive counterpart lies on the other side, so it adds one probe when the walk stops short of it.
    static func tryEnterCrossZero(state: inout State) -> Bool {
        let leaf = state.leafPositions[state.leafIndex]
        guard leaf.typeTag.isSigned else {
            return false
        }
        guard let currentEntry = state.sequence[leaf.sequenceIndex].value else {
            return false
        }
        let currentKey = currentEntry.choice.shortlexKey
        guard currentKey > 0 else {
            return false
        }

        // Skip cross-zero when zero is outside an explicit range. The walk probes keys near zero, which are then almost certainly out of range too, so a generator like `int(in: 1...1000)` would spend the whole budget on rejected probes.
        //
        // Zero's bit pattern comes from `semanticSimplest`, because the signed encoding maps bit pattern 0 to the most negative value.
        if currentEntry.isRangeExplicit, let range = currentEntry.validRange {
            let zeroBitPattern = currentEntry.choice.semanticSimplest.bitPattern64
            if range.contains(zeroBitPattern) == false {
                return false
            }
            // Retain the endpoint shortcut unless an admissible positive counterpart exists. A negative lower bound can improve by changing sign; a type's unpaired minimum has no counterpart.
            let currentBitPattern = currentEntry.choice.bitPattern64
            if currentBitPattern == range.lowerBound || currentBitPattern == range.upperBound {
                guard positiveCounterpart(of: currentEntry) != nil else {
                    return false
                }
            }
        }

        // ⌈log₂(currentKey + 1)⌉ + 4, capped at 16.
        let bitLength = UInt64(64 - currentKey.leadingZeroBitCount)
        let budget = min(bitLength + 4, 16)
        let endKey = min(currentKey, budget)

        var counterpartKey = positiveCounterpart(of: currentEntry)?.shortlexKey
        if let key = counterpartKey, key < endKey {
            // The walk reaches it.
            counterpartKey = nil
        }

        state.crossZero = CrossZeroState(
            sequenceIndex: leaf.sequenceIndex,
            tag: leaf.typeTag,
            validRange: currentEntry.validRange,
            isRangeExplicit: currentEntry.isRangeExplicit,
            nextKey: 0,
            endKey: endKey,
            counterpartKey: counterpartKey,
            lastEmittedKey: nil
        )
        return true
    }

    /// The positive value with the magnitude of a negative entry, when the entry's explicit range admits it.
    private static func positiveCounterpart(of entry: ChoiceSequenceValue.Value) -> ChoiceValue? {
        guard entry.choice.hasNegativeSign,
              let counterpart = entry.choice.signFlipped,
              entry.isRangeExplicit == false || counterpart.fits(in: entry.validRange)
        else {
            return nil
        }
        return counterpart
    }

    /// Drives the cross-zero phase for the current leaf.
    ///
    /// Walks shortlex keys up from zero, one candidate per call. The first accepted probe is the simplest value the walk can reach, so the phase ends there.
    ///
    /// Returns `nil` when the walk is exhausted (all probes rejected or budget reached) or when the caller should advance to the next leaf (acceptance happened on the prior call). The caller clears ``State/crossZero`` and advances `leafIndex` when `nil` is returned.
    static func nextCrossZeroProbe(
        state: inout State,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        guard var crossZero = state.crossZero else {
            return nil
        }

        if let acceptedKey = crossZero.lastEmittedKey {
            crossZero.lastEmittedKey = nil
            if lastAccepted {
                // `next` has already made the accepted candidate the baseline. Record its bit pattern so the next pass's binary search warm-starts from it.
                state.recordCrossZeroAcceptance(acceptedKey, tag: crossZero.tag, nodeID: state.leafPositions[state.leafIndex].nodeID)
                state.crossZero = crossZero
                return nil
            }
        }

        while crossZero.nextKey < crossZero.endKey {
            let probeKey = crossZero.nextKey
            crossZero.nextKey += 1

            let probeChoice = simplestSignedValue(rank: probeKey, tag: crossZero.tag)

            // The materializer rejects a probe outside an explicit range, so skip it rather than spend a probe.
            if crossZero.isRangeExplicit,
               probeChoice.fits(in: crossZero.validRange) == false
            {
                continue
            }

            return emitCrossZeroProbe(key: probeKey, crossZero: &crossZero, state: &state)
        }

        // Range admission was checked when the phase was armed.
        if let counterpartKey = crossZero.counterpartKey {
            crossZero.counterpartKey = nil
            return emitCrossZeroProbe(key: counterpartKey, crossZero: &crossZero, state: &state)
        }

        state.crossZero = crossZero
        return nil
    }

    /// Records `key` as the outstanding probe and returns the sequence with the leaf set to its decoded value.
    private static func emitCrossZeroProbe(
        key: UInt64,
        crossZero: inout CrossZeroState,
        state: inout State
    ) -> ChoiceSequence {
        crossZero.lastEmittedKey = key
        state.crossZero = crossZero

        var candidate = state.sequence
        candidate[crossZero.sequenceIndex] = .value(.init(
            choice: simplestSignedValue(rank: key, tag: crossZero.tag),
            validRange: crossZero.validRange,
            isRangeExplicit: crossZero.isRangeExplicit
        ))
        return candidate
    }

    /// The signed value at `rank` in the order 0, 1, −1, 2, −2, and so on, which is the rank ``ChoiceValue/shortlexKey`` assigns it.
    ///
    /// Defined for every rank below the type's unpaired minimum, the one value without a negation. Cross-zero never reaches that rank: it walks at most 16 ranks and otherwise probes only a positive counterpart.
    private static func simplestSignedValue(rank: UInt64, tag: TypeTag) -> ChoiceValue {
        let positive = ChoiceValue(tag.simplestBitPattern + rank / 2 + rank % 2, tag: tag)
        guard rank.isMultiple(of: 2), let negative = positive.signFlipped else {
            return positive
        }
        return negative
    }
}

// MARK: - Convergence Records

extension IntegerSearch.State {
    /// Replaces the bound of the leaf's existing record, keeping its signal and configuration. Does nothing when the leaf has no record.
    mutating func lowerRecordedBound(to bound: UInt64, nodeID: Int) {
        guard let record = convergenceStore[nodeID] else {
            return
        }
        convergenceStore[nodeID] = ConvergedOrigin(
            bound: bound,
            signal: record.signal,
            configuration: record.configuration,
            cycle: record.cycle
        )
    }

    /// Records an accepted cross-zero probe as the leaf's binary search bound.
    mutating func recordCrossZeroAcceptance(_ acceptedKey: UInt64, tag: TypeTag, nodeID: Int) {
        let acceptedChoice = IntegerSearch.simplestSignedValue(rank: acceptedKey, tag: tag)
        convergenceStore[nodeID] = ConvergedOrigin(
            bound: acceptedChoice.bitPattern64,
            signal: .monotoneConvergence,
            configuration: .binarySearchSemanticSimplest,
            cycle: 0
        )
    }
}
