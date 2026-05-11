//
//  ChoiceGraphScheduler+RelaxRound.swift
//  Exhaust
//

// MARK: - Structural Relax Round

extension ChoiceGraphScheduler {
    /// Runs a structural relax-solve-round pass: checkpoint, apply a shortlex-worsening structural perturbation, reduce from the perturbed state, commit if the result beats the checkpoint.
    ///
    /// - Returns: True if the relax round produced a net improvement (committed).
    static func runRelaxRound(state: inout ReductionState) throws -> Bool {
        let checkpointSequence = state.sequence
        let checkpointTree = state.tree
        let checkpointOutput = state.output
        let checkpointConvergence = extractAllConvergence(from: state.graph)

        Self.logReducer("relax_round_start", isInstrumented: state.isInstrumented, metadata: [
            "seq_len": "\(state.sequence.count)",
        ])

        let candidates = buildRelaxCandidates(
            sequence: state.sequence,
            graph: state.graph
        )

        guard candidates.isEmpty == false else {
            Self.logReducer("relax_round_no_candidates", isInstrumented: state.isInstrumented, metadata: [:])
            return false
        }

        Self.logReducer("relax_round_candidates", isInstrumented: state.isInstrumented, metadata: [
            "count": "\(candidates.count)",
        ])

        let materializationBudget = state.tuning.relaxMaterializationBudget
        var perturbationAccepted = false
        var materializationsUsed = 0
        for candidate in candidates {
            guard materializationsUsed < materializationBudget else { break }
            let decoder: SequenceDecoder = .exact(materializePicks: true)
            var filterObservations: [UInt64: FilterObservation] = [:]

            if let result = try decoder.decodeAny(
                candidate: candidate,
                gen: state.gen,
                tree: state.tree,
                originalSequence: state.sequence,
                property: state.property,
                filterObservations: &filterObservations
            ) {
                state.sequence = result.sequence
                state.tree = result.tree
                state.output = result.output
                perturbationAccepted = true

                Self.logReducer("relax_round_perturbation_accepted", isInstrumented: state.isInstrumented, metadata: [
                    "seq_len": "\(state.sequence.count)",
                ])
                break
            }

            materializationsUsed += 1
            if state.collectStats {
                state.stats.totalMaterializations += 1
            }
        }

        guard perturbationAccepted else {
            Self.logReducer("relax_round_no_perturbation", isInstrumented: state.isInstrumented, metadata: [:])
            return false
        }

        state.graph = rebuildGraph(from: state.tree, replacing: state.graph, stats: &state.stats)
        var exploitSources = CandidateSourceBuilder.buildSources(from: state.graph)

        Self.logReducer("relax_round_exploitation_start", isInstrumented: state.isInstrumented, metadata: [
            "seq_len": "\(state.sequence.count)", "sources": "\(exploitSources.count)",
        ])

        let savedRejectCache = state.rejectCache
        state.rejectCache = []
        while true {
            guard let sourceIndex = highestPrioritySourceIndex(exploitSources) else {
                break
            }
            guard let exploitTransformation = exploitSources[sourceIndex].next(lastAccepted: false) else {
                exploitSources.swapAt(sourceIndex, exploitSources.count - 1)
                exploitSources.removeLast()
                continue
            }
            guard exploitTransformation.operation.isValid(in: state.graph) else {
                continue
            }
            if case .minimize(.boundValue) = exploitTransformation.operation {
                continue
            }

            let warmStarts = extractWarmStarts(from: state.graph)
            let exploitScope = EncoderInput(
                transformation: exploitTransformation,
                baseSequence: state.sequence,
                tree: state.tree,
                graph: state.graph,
                warmStartRecords: warmStarts
            )

            var exploitEncoder = selectEncoder(for: exploitTransformation.operation)
            let outcome = try runProbeLoop(
                encoder: &exploitEncoder,
                scope: exploitScope,
                state: &state
            )

            let convergence = exploitEncoder.convergenceRecords
            if convergence.isEmpty == false {
                state.graph.recordConvergence(byNodeID: convergence)
            }

            if outcome.accepted, outcome.requiresRebuild {
                state.graph = rebuildGraph(from: state.tree, replacing: state.graph, stats: &state.stats)
                exploitSources = CandidateSourceBuilder.buildSources(from: state.graph)
            }
        }
        state.rejectCache = savedRejectCache

        if state.sequence.shortLexPrecedes(checkpointSequence) {
            Self.logReducer("relax_round_committed", isInstrumented: state.isInstrumented, metadata: [
                "old_seq_len": "\(checkpointSequence.count)", "new_seq_len": "\(state.sequence.count)",
            ])
            return true
        }

        state.sequence = checkpointSequence
        state.tree = checkpointTree
        state.output = checkpointOutput
        state.graph = rebuildGraph(from: state.tree, replacing: state.graph, stats: &state.stats)
        transferConvergence(checkpointConvergence, to: &state.graph)

        Self.logReducer("relax_round_rolled_back", isInstrumented: state.isInstrumented, metadata: [
            "seq_len": "\(state.sequence.count)",
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
            case let .branch(_, _, candidateID, _, _, _):
                candidateID == targetBranchID
            default:
                false
            }
        }) else { return nil }

        let minimizedTarget = GraphStructuralEncoder.minimizingLeaves(in: elements[targetElementIndex])
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
