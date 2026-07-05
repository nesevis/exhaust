//
//  ReductionMachine+RelaxRound.swift
//  Exhaust
//

// MARK: - Structural Relax Round

extension ReductionMachine {
    /// Runs a structural relax-solve-round pass: checkpoint, apply a shortlex-worsening structural perturbation, reduce from the perturbed state, commit if the result beats the checkpoint.
    ///
    /// - Returns: True if the relax round produced a net improvement (committed).
    mutating func runRelaxRound() throws -> Bool {
        let checkpointSequence = sequence
        let checkpointTree = tree
        let checkpointOutput = output
        let checkpointConvergence = ChoiceGraphScheduler.extractAllConvergence(from: graph)
        // The exploitation loop applies pass reports that set these per-cycle flags. On rollback the committed counterexample is unchanged, so the flags must be restored too — otherwise a stale `anyAccepted` defers termination for a cycle that produced nothing.
        let checkpointAnyAccepted = anyAccepted
        let checkpointShortlexRejection = hadReplacementShortlexRejection

        // Value-only deadline probe: `self` is passed `inout` below, so the closure captures the deadline bounds rather than `self`.
        let deadlineNanos = deadlineNanoseconds
        let startNanos = startNanoseconds
        let deadlineCheck: () -> Bool = {
            guard deadlineNanos > 0 else { return false }
            return monotonicNanoseconds() - startNanos >= deadlineNanos
        }

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
        for candidate in candidates {
            guard materializationsUsed < materializationBudget else { break }
            guard deadlineCheck() == false else { break }
            let decoder: SequenceDecoder = .exact(materializePicks: true)
            var filterObservations: [UInt64: FilterObservation] = [:]

            if let result = try decoder.decodeAny(
                candidate: candidate,
                gen: gen,
                tree: tree,
                originalSequence: sequence,
                property: property,
                filterObservations: &filterObservations
            ) {
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
            if collectStats {
                stats.totalMaterializations += 1
            }
        }

        guard perturbationAccepted else {
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
            if case .minimize(.boundValue) = exploitTransformation.operation {
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

            var exploitEncoder = ChoiceGraphScheduler.selectEncoder(for: exploitTransformation.operation)
            exploitEncoder.start(scope: exploitScope)

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

        if sequence.shortLexPrecedes(checkpointSequence) {
            ChoiceGraphScheduler.logReducer("relax_round_committed", isInstrumented: isInstrumented, metadata: [
                "old_seq_len": "\(checkpointSequence.count)", "new_seq_len": "\(sequence.count)",
            ])
            return true
        }

        sequence = checkpointSequence
        tree = checkpointTree
        output = checkpointOutput
        anyAccepted = checkpointAnyAccepted
        hadReplacementShortlexRejection = checkpointShortlexRejection
        _ = rebuildAndUpdateGraph()
        ChoiceGraphScheduler.transferConvergence(checkpointConvergence, to: &graph)

        ChoiceGraphScheduler.logReducer("relax_round_rolled_back", isInstrumented: isInstrumented, metadata: [
            "seq_len": "\(sequence.count)",
        ])
        return false
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
                    if let candidate = buildUnguardedBranchPivot(
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

    private static func buildUnguardedBranchPivot(
        pickNodeID: Int,
        targetBranchID: UInt64,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ChoiceSequence? {
        guard pickNodeID < graph.nodes.count else { return nil }
        guard case let .pick(pickMetadata) = graph.nodes[pickNodeID].kind else { return nil }
        guard let pickRange = graph.nodes[pickNodeID].positionRange else { return nil }

        let elements = pickMetadata.branchElements
        guard pickMetadata.selectedChildIndex < elements.count else { return nil }

        guard let targetElementIndex = elements.firstIndex(where: { element in
            switch element {
                case let .branch(b):
                    b.id == targetBranchID
                default:
                    false
            }
        }) else { return nil }

        let minimizedTarget = elements[targetElementIndex].minimizingLeaves
        let targetContent = ChoiceSequence.flatten(minimizedTarget.selecting())

        var replacement: [ChoiceSequenceValue] = []
        replacement.reserveCapacity(targetContent.count + 3)
        replacement.append(.group(true))
        replacement.append(.branch(.init(id: targetBranchID, branchCount: pickMetadata.branchCount)))
        replacement.append(contentsOf: targetContent)
        replacement.append(.group(false))

        var candidate = sequence
        candidate.replaceSubrange(pickRange.lowerBound ... pickRange.upperBound, with: replacement)
        return candidate
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
