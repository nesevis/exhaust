//
//  ReductionMachine+RelaxRound.swift
//  Exhaust
//

// MARK: - Structural Relax Round

extension ReductionMachine {
    /// Runs a relax round: improving pivot probes, then a structural excursion.
    ///
    /// An accepted improving probe already precedes the current sequence, so it returns without a checkpoint. The excursion checkpoints, applies a shortlex-worsening perturbation, reduces from it, and commits only if the result beats the checkpoint.
    ///
    /// - Returns: True if the relax round produced a net improvement (committed).
    mutating func runRelaxRound() throws -> Bool {
        // Value-only deadline probe: `self` is passed `inout` below, so the closure captures the deadline bounds rather than `self`.
        let deadlineNanos = deadlineNanoseconds
        let startNanos = startNanoseconds
        let deadlineCheck: () -> Bool = {
            guard deadlineNanos > 0 else { return false }
            return monotonicNanoseconds() - startNanos >= deadlineNanos
        }

        // Before the checkpoint, which an accepted improving probe does not need.
        if try runImprovingPivotProbes(deadlineCheck: deadlineCheck) {
            return true
        }

        let checkpointSequence = sequence
        let checkpointTree = tree
        let checkpointOutput = output
        let checkpointConvergence = ChoiceGraphScheduler.extractAllConvergence(from: graph)
        // The exploitation loop applies pass reports that set these per-cycle flags. On rollback the committed counterexample is unchanged, so the flags must be restored too. Otherwise a stale `anyAccepted` defers termination for a cycle that produced nothing.
        let checkpointAnyAccepted = anyAccepted
        let checkpointUnresolvedReplacement = hadUnresolvedReplacement

        ChoiceGraphScheduler.logReducer("relax_round_start", isInstrumented: isInstrumented, metadata: [
            "seq_len": "\(sequence.count)",
        ])

        let candidates = Self.buildRelaxCandidates(
            sequence: sequence,
            graph: graph
        )

        guard candidates.isEmpty == false else {
            ChoiceGraphScheduler.logReducer("relax_round_no_candidates", isInstrumented: isInstrumented, metadata: [:])
            return false
        }

        ChoiceGraphScheduler.logReducer("relax_round_candidates", isInstrumented: isInstrumented, metadata: [
            "count": "\(candidates.count)",
        ])

        let materializationBudget = tuning.relaxMaterializationBudget
        var perturbationAccepted = false
        var materializationsUsed = 0
        var probeCounts = ReductionProbeCounts()
        defer {
            if collectStats {
                stats.recordStructuralRelax(probeCounts)
            }
        }
        for candidate in candidates {
            guard materializationsUsed < materializationBudget else { break }
            guard deadlineCheck() == false else { break }
            probeCounts.recordEmission()
            let decoder: SequenceDecoder = .exact(materializePicks: true)
            var filterObservations: [UInt64: FilterObservation] = [:]

            let outcome = try decoder.decodeAny(
                candidate: candidate,
                gen: gen,
                tree: tree,
                originalSequence: sequence,
                property: wrappedProperty(for: candidate),
                filterObservations: &filterObservations
            )
            probeCounts.record(outcome)

            if let result = outcome.reduction {
                sequence = result.sequence
                tree = result.tree
                output = result.output
                perturbationAccepted = true

                ChoiceGraphScheduler.logReducer("relax_round_perturbation_accepted", isInstrumented: isInstrumented, metadata: [
                    "seq_len": "\(sequence.count)",
                ])
                break
            }

            materializationsUsed += 1
        }

        guard perturbationAccepted else {
            if collectDiagnostics {
                stats.relaxRoundLog.append(RelaxRoundRecord(
                    candidateCount: candidates.count,
                    materializationsUsed: materializationsUsed,
                    perturbationDecoded: false,
                    committed: false
                ))
            }
            ChoiceGraphScheduler.logReducer("relax_round_no_perturbation", isInstrumented: isInstrumented, metadata: [:])
            return false
        }

        _ = rebuildAndUpdateGraph()
        var exploitSources = CandidateSourceBuilder.buildSources(from: graph)

        ChoiceGraphScheduler.logReducer("relax_round_exploitation_start", isInstrumented: isInstrumented, metadata: [
            "seq_len": "\(sequence.count)", "sources": "\(exploitSources.count)",
        ])

        let savedRejectCache = rejectCache
        rejectCache = []
        while true {
            guard deadlineCheck() == false else { break }
            guard let sourceIndex = ChoiceGraphScheduler.highestPrioritySourceIndex(exploitSources) else {
                break
            }
            guard let exploitTransformation = exploitSources[sourceIndex].next(lastAccepted: false) else {
                exploitSources.swapAt(sourceIndex, exploitSources.count - 1)
                exploitSources.removeLast()
                continue
            }
            guard exploitTransformation.operation.isValid(in: graph) else {
                continue
            }
            guard exploitTransformation.operation.requiresGenerator == false else {
                continue
            }

            let warmStarts = ChoiceGraphScheduler.extractWarmStarts(from: graph)
            let exploitScope = EncoderInput(
                transformation: exploitTransformation,
                baseSequence: sequence,
                tree: tree,
                graph: graph,
                warmStartRecords: warmStarts
            )

            var exploitEncoder = ChoiceGraphScheduler.selectEncoder(for: exploitTransformation.operation, gen: gen)
            exploitEncoder.start(scope: exploitScope)

            captureDispatchBaseline()
            var session = ProbeSession(
                encoder: exploitEncoder,
                transformation: exploitTransformation,
                boundValueFingerprint: nil,
                baseSequence: sequence,
                hasBind: sequence.contains { if case .bind = $0 { return true }; return false }
            )
            let report = try session.runToCompletion(state: &self, deadlineCheck: deadlineCheck)

            _ = applyPassReport(report)

            if report.anyAccepted, report.anyRequiresRebuild {
                _ = rebuildAndUpdateGraph(
                    valueGuardExemptNodeIDs: report.acceptedLeafNodeIDs
                        .union(report.convergenceRecords.keys)
                )
                exploitSources = CandidateSourceBuilder.buildSources(from: graph)
            }
        }
        rejectCache = savedRejectCache

        let excursionCommitted = sequence.shortLexPrecedes(checkpointSequence)
        if collectDiagnostics {
            stats.relaxRoundLog.append(RelaxRoundRecord(
                candidateCount: candidates.count,
                materializationsUsed: materializationsUsed,
                perturbationDecoded: true,
                committed: excursionCommitted
            ))
        }

        if excursionCommitted {
            ChoiceGraphScheduler.logReducer("relax_round_committed", isInstrumented: isInstrumented, metadata: [
                "old_seq_len": "\(checkpointSequence.count)", "new_seq_len": "\(sequence.count)",
            ])
            return true
        }

        sequence = checkpointSequence
        tree = checkpointTree
        output = checkpointOutput
        anyAccepted = checkpointAnyAccepted
        hadUnresolvedReplacement = checkpointUnresolvedReplacement
        _ = rebuildAndUpdateGraph()
        ChoiceGraphScheduler.transferConvergence(checkpointConvergence, to: &graph)

        ChoiceGraphScheduler.logReducer("relax_round_rolled_back", isInstrumented: isInstrumented, metadata: [
            "seq_len": "\(sequence.count)",
        ])
        return false
    }

    // MARK: - Improving Pivot Probes

    /// Probes improving pivots at non-minimal content and accepts the first that still fails the property.
    ///
    /// The next cycle minimizes the accepted arm under ordinary scheduling, so no exploitation runs here.
    private mutating func runImprovingPivotProbes(deadlineCheck: () -> Bool) throws -> Bool {
        let budget = tuning.relaxImprovingProbeBudget
        guard budget > 0 else {
            return false
        }
        var probesUsed = 0
        var probeCounts = ReductionProbeCounts()
        defer {
            if collectStats {
                stats.recordStructuralRelax(probeCounts)
                stats.relaxImprovingProbes += probesUsed
            }
        }
        for (candidate, probeHash) in unprobedImprovingPivotCandidates() {
            guard probesUsed < budget, deadlineCheck() == false else {
                break
            }
            probesUsed += 1
            probeCounts.recordEmission()
            let decoder: SequenceDecoder = .exact(materializePicks: true)
            var filterObservations: [UInt64: FilterObservation] = [:]
            let outcome = try decoder.decodeAny(
                candidate: candidate,
                gen: gen,
                tree: tree,
                originalSequence: sequence,
                property: wrappedProperty(for: candidate),
                filterObservations: &filterObservations
            )
            probeCounts.record(outcome)

            guard let result = outcome.reduction, result.sequence.shortLexPrecedes(sequence) else {
                rejectCache.insert(probeHash)
                continue
            }
            sequence = result.sequence
            tree = result.tree
            output = result.output
            if collectStats {
                stats.relaxImprovingAcceptances += 1
            }
            _ = rebuildAndUpdateGraph()
            ChoiceGraphScheduler.logReducer("relax_round_improving_pivot_accepted", isInstrumented: isInstrumented, metadata: [
                "seq_len": "\(sequence.count)", "probes": "\(probesUsed)",
            ])
            return true
        }
        return false
    }

    /// Whether the improving phase has a probe to spend.
    var hasUnprobedImprovingPivot: Bool {
        tuning.relaxImprovingProbeBudget > 0 && unprobedImprovingPivotCandidates().isEmpty == false
    }

    /// Improving pivot candidates absent from the reject cache, so exhausted pivots stop triggering relax rounds.
    private func unprobedImprovingPivotCandidates() -> [(candidate: ChoiceSequence, probeHash: UInt64)] {
        Self.buildImprovingPivotCandidates(sequence: sequence, graph: graph).compactMap { candidate in
            let probeHash = ZobristHash.hash(of: candidate)
            guard rejectCache.contains(probeHash) == false else {
                return nil
            }
            return (candidate, probeHash)
        }
    }

    /// Non-minimal fills of every pivot that precedes `sequence`, shortest first. Precedence is independent of the fill, so the first fill decides for the scope.
    private static func buildImprovingPivotCandidates(
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> [ChoiceSequence] {
        var candidates: [ChoiceSequence] = []
        for scope in ReplacementQuery.build(graph: graph) {
            guard case let .branchPivot(pickNodeID, targetBranchID) = scope else {
                continue
            }
            for fill in [PivotLeafFill.recorded, .farthestFromTarget] {
                guard let candidate = GraphStructuralEncoder.branchPivotCandidate(
                    pickNodeID: pickNodeID,
                    targetBranchID: targetBranchID,
                    fill: fill,
                    sequence: sequence,
                    graph: graph
                ), candidate.shortLexPrecedes(sequence) else {
                    break
                }
                candidates.append(candidate)
            }
        }
        candidates.sort { $0.count < $1.count }
        return candidates
    }

    // MARK: - Perturbation Candidate Construction

    private static func buildRelaxCandidates(
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> [ChoiceSequence] {
        var candidates: [ChoiceSequence] = []

        for scope in ReplacementQuery.build(graph: graph) {
            switch scope {
                case let .branchPivot(pickNodeID, targetBranchID):
                    if let candidate = GraphStructuralEncoder.branchPivotCandidate(
                        pickNodeID: pickNodeID,
                        targetBranchID: targetBranchID,
                        sequence: sequence,
                        graph: graph
                    ) {
                        candidates.append(candidate)
                    }

                case let .selfSimilar(targetNodeID, donorNodeID, _):
                    if let candidate = buildUnguardedSelfSimilar(
                        targetNodeID: targetNodeID,
                        donorNodeID: donorNodeID,
                        sequence: sequence,
                        graph: graph
                    ) {
                        candidates.append(candidate)
                    }

                case let .descendantPromotion(ancestorPickNodeID, descendantPickNodeID, _):
                    if let candidate = buildUnguardedDescendantPromotion(
                        ancestorPickNodeID: ancestorPickNodeID,
                        descendantPickNodeID: descendantPickNodeID,
                        sequence: sequence,
                        graph: graph
                    ) {
                        candidates.append(candidate)
                    }
            }
        }

        // Length only, deliberately not full shortlex. A lex tiebreak among equal-length candidates was tried and reverted: it preferred perturbations that decode successfully, triggering full exploitation loops in relax rounds that previously ended cheaply at the perturbation stage.
        candidates.sort { $0.count < $1.count }
        return candidates
    }

    private static func buildUnguardedSelfSimilar(
        targetNodeID: Int,
        donorNodeID: Int,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ChoiceSequence? {
        guard let targetRange = graph.nodes[targetNodeID].positionRange,
              let donorRange = graph.nodes[donorNodeID].positionRange
        else { return nil }
        let donorEntries = Array(sequence[donorRange.lowerBound ... donorRange.upperBound])
        let expanded = GraphStructuralEncoder.expandDepthZeroLeaves(
            donorEntries,
            donorNodeID: donorNodeID,
            donorRangeStart: donorRange.lowerBound,
            graph: graph
        )
        var candidate = sequence
        candidate.replaceSubrange(targetRange.lowerBound ... targetRange.upperBound, with: expanded)
        guard candidate != sequence else { return nil }
        return candidate
    }

    private static func buildUnguardedDescendantPromotion(
        ancestorPickNodeID: Int,
        descendantPickNodeID: Int,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ChoiceSequence? {
        guard let ancestorRange = graph.nodes[ancestorPickNodeID].positionRange,
              let descendantRange = graph.nodes[descendantPickNodeID].positionRange
        else { return nil }
        let descendantEntries = Array(sequence[descendantRange.lowerBound ... descendantRange.upperBound])
        let expanded = GraphStructuralEncoder.expandDepthZeroLeaves(
            descendantEntries,
            donorNodeID: descendantPickNodeID,
            donorRangeStart: descendantRange.lowerBound,
            graph: graph
        )
        var candidate = sequence
        candidate.replaceSubrange(ancestorRange.lowerBound ... ancestorRange.upperBound, with: expanded)
        guard candidate != sequence else { return nil }
        return candidate
    }
}
