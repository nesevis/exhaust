//
//  ReductionState+AntichainComposition.swift
//  Exhaust
//
//  Created by Chris Kolbu on 25/3/2026.
//

// MARK: - Antichain Composition

//
// Extends ReductionState with the antichain composition algorithm for structural deletion. Delta-debugging over the maximal antichain of the CDG finds the largest jointly-deletable subset of structurally independent spans.

extension ReductionState {
    /// Applies delta-debugging over the maximal antichain of the CDG to find the largest jointly-deletable subset of structurally independent spans.
    ///
    /// Populates each antichain node with its best deletion candidate from the span cache, then searches for the maximal subset whose joint deletion preserves the property failure. Only activates when the antichain has more than two members; below that, pair enumeration in the ``MutationPool`` fallback is simpler and equally capable.
    func runAntichainComposition(
        dag: ChoiceDependencyGraph,
        budget: inout ReductionScheduler.LegBudget
    ) throws -> Bool {
        let antichainNodes = dag.maximalAntichain()
        guard antichainNodes.count > 2 else { return false }

        // Populate each antichain node with the best deletion candidate across all slot categories.
        let candidates = collectAntichainCandidates(
            antichainNodes: antichainNodes,
            dag: dag
        )
        guard candidates.count > 2 else { return false }

        let decoder = makeSpeculativeDecoder()

        // Delta-debug over the antichain to find the maximal jointly-deletable subset.
        let accepted = try findMaximalDeletableSubset(
            candidates: candidates,
            decoder: decoder,
            budget: &budget
        )

        if let accepted {
            let totalDeleted = accepted.reduce(0) { $0 + $1.deletedLength }
            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "bonsai_phase1_accepted",
                    metadata: [
                        "subphase": "antichain",
                        "antichain_size": "\(candidates.count)",
                        "accepted_k": "\(accepted.count)",
                        "deleted_length": "\(totalDeleted)",
                    ]
                )
            }
            return true
        }

        return false
    }

    /// Collects the best deletion candidate for each antichain node by querying the span cache across all slot categories within the node's scope range.
    ///
    /// Returns candidates sorted by `deletedLength` descending so the delta-debugging binary split places high-impact nodes in the first half. Excludes nodes with no deletable spans in any slot category.
    private func collectAntichainCandidates(
        antichainNodes: [Int],
        dag: ChoiceDependencyGraph
    ) -> [(nodeIndex: Int, spans: [ChoiceSpan], deletedLength: Int)] {
        var candidates = [(nodeIndex: Int, spans: [ChoiceSpan], deletedLength: Int)]()

        for nodeIndex in antichainNodes {
            guard let scopeRange = dag.nodes[nodeIndex].scopeRange else { continue }

            var bestSpans = [ChoiceSpan]()
            var bestLength = 0

            // Try each deletion slot category; keep the one with the most deleted material.
            for slot in ReductionScheduler.DeletionEncoderSlot.allCases {
                let spans = spanCache.deletionTargets(
                    category: slot.spanCategory,
                    inRange: scopeRange,
                    from: sequence
                )
                guard spans.isEmpty == false else { continue }
                let totalLength = spans.reduce(0) { $0 + $1.range.count }
                if totalLength > bestLength {
                    bestSpans = spans
                    bestLength = totalLength
                }
            }

            if bestSpans.isEmpty == false {
                candidates.append((
                    nodeIndex: nodeIndex,
                    spans: bestSpans,
                    deletedLength: bestLength
                ))
            }
        }

        // Sort by deletedLength descending so the binary split in delta-debugging places
        // high-impact nodes in the first half.
        candidates.sort { $0.deletedLength > $1.deletedLength }
        return candidates
    }

    /// Finds the maximal subset of the antichain whose joint deletion preserves the property failure.
    ///
    /// Splits the antichain in half, recurses into both halves, takes the larger successful subset, then greedily extends it over the full complement (not just the unchosen half) to discover cross-half compositions.
    ///
    /// - Complexity: O(*n* · log *n*) property evaluations where *n* is the antichain size.
    private func findMaximalDeletableSubset(
        candidates: [(nodeIndex: Int, spans: [ChoiceSpan], deletedLength: Int)],
        decoder: SequenceDecoder,
        budget: inout ReductionScheduler.LegBudget
    ) throws -> [(nodeIndex: Int, spans: [ChoiceSpan], deletedLength: Int)]? {
        guard budget.isExhausted == false else { return nil }

        // Try the full set first — cheapest possible success.
        let allSpans = candidates.flatMap(\.spans)
        if let result = try testComposition(spans: allSpans, decoder: decoder, budget: &budget) {
            accept(result, structureChanged: true)
            return candidates
        }

        guard candidates.count > 1 else { return nil }

        // Binary split and recurse.
        let mid = candidates.count / 2
        let left = Array(candidates[..<mid])
        let right = Array(candidates[mid...])

        let leftResult = try findMaximalDeletableSubset(
            candidates: left,
            decoder: decoder,
            budget: &budget
        )
        let rightResult = try findMaximalDeletableSubset(
            candidates: right,
            decoder: decoder,
            budget: &budget
        )

        // Take the larger successful subset.
        var best: [(nodeIndex: Int, spans: [ChoiceSpan], deletedLength: Int)]
        switch (leftResult, rightResult) {
        case let (leftFound?, rightFound?):
            best = leftFound.count >= rightFound.count ? leftFound : rightFound
        case let (leftFound?, nil):
            best = leftFound
        case let (nil, rightFound?):
            best = rightFound
        case (nil, nil):
            return nil
        }

        // Greedy extension: try adding each candidate from the full complement, not just the
        // unchosen half. This is critical for discovering cross-half compositions — if the left
        // found {A, B} and the right found {C}, extending {A, B} over the full complement tries
        // adding C, D, E, ... including elements from the right half.
        let bestNodeIndices = Set(best.map(\.nodeIndex))
        for candidate in candidates where bestNodeIndices.contains(candidate.nodeIndex) == false {
            guard budget.isExhausted == false else { break }
            let extendedSpans = best.flatMap(\.spans) + candidate.spans
            if let result = try testComposition(
                spans: extendedSpans,
                decoder: decoder,
                budget: &budget
            ) {
                // Re-accept with the extended composition. The previous accept from the recursive
                // call set the state; this overwrites it with the strictly better result.
                accept(result, structureChanged: true)
                best.append(candidate)
            }
        }

        return best
    }

    /// Composes a set of spans into a single deletion candidate via range-set union and tests it against the property.
    ///
    /// Returns the accepted ``ReductionResult`` if the candidate preserves the failure and is shortlex-smaller than the current sequence, or `nil` if the candidate is rejected or cache-hit.
    private func testComposition(
        spans: [ChoiceSpan],
        decoder: SequenceDecoder,
        budget: inout ReductionScheduler.LegBudget
    ) throws -> ReductionResult<Output>? {
        var rangeSet = RangeSet<Int>()
        for span in spans {
            rangeSet.insert(contentsOf: span.range.asRange)
        }
        var candidate = sequence
        candidate.removeSubranges(rangeSet)
        guard candidate.shortLexPrecedes(sequence) else { return nil }

        let cacheKey = ZobristHash.hash(of: candidate) &+ decoder.rejectCacheSalt
        if rejectCache.contains(cacheKey) {
            return nil
        }

        let result = try decoder.decode(
            candidate: candidate,
            gen: gen,
            tree: tree,
            originalSequence: sequence,
            property: property
        )
        budget.recordMaterialization()
        phaseTracker.recordInvocation()

        if result == nil {
            rejectCache.insert(cacheKey)
        }
        return result
    }
}
