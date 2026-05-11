//
//  ChoiceGraphScheduler+RelaxRound.swift
//  Exhaust
//

// MARK: - Structural Relax Round

extension ChoiceGraphScheduler {
    /// Runs a structural relax–solve–round pass: checkpoint, apply a shortlex-worsening structural perturbation, reduce from the perturbed state, commit if the result beats the checkpoint.
    ///
    /// The relaxation removes the shortlex constraint on structural operations — branch pivots, self-similar substitutions, and descendant promotions that the standard encoder rejected because the candidate was shortlex-larger. The exploitation phase runs a full reduction cycle from the perturbed state. The round phase compares the exploited result against the checkpoint and commits only if the final state is strictly better.
    ///
    /// Perturbation candidates are built directly from the graph's replacement scopes with the shortlex gate removed. Each candidate is materialized and property-checked; the first property-failing candidate seeds the exploitation phase.
    ///
    /// - Returns: True if the relax round produced a net improvement (committed).
    // swiftlint:disable function_parameter_count
    static func runRelaxRound(
        sequence: inout ChoiceSequence,
        tree: inout ChoiceTree,
        output: inout Any,
        graph: inout ChoiceGraph,
        gen: ReflectiveGenerator<Any>,
        property: @escaping (Any) -> Bool,
        rejectCache: inout Set<UInt64>,
        stats: inout ReductionStats,
        collectStats: Bool,
        isInstrumented: Bool
    ) throws -> Bool {
        let checkpointSequence = sequence
        let checkpointTree = tree
        let checkpointOutput = output
        let checkpointConvergence = extractAllConvergence(from: graph)

        if isInstrumented {
            ExhaustLog.debug(
                category: .reducer,
                event: "relax_round_start",
                metadata: ["seq_len": "\(sequence.count)"]
            )
        }

        let candidates = buildRelaxCandidates(
            sequence: sequence,
            graph: graph
        )

        guard candidates.isEmpty == false else {
            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "relax_round_no_candidates",
                    metadata: [:]
                )
            }
            return false
        }

        if isInstrumented {
            ExhaustLog.debug(
                category: .reducer,
                event: "relax_round_candidates",
                metadata: ["count": "\(candidates.count)"]
            )
        }

        // Try perturbation candidates until one fails the property or the budget is exhausted.
        let materializationBudget = 10
        var perturbationAccepted = false
        var materializationsUsed = 0
        for candidate in candidates {
            guard materializationsUsed < materializationBudget else { break }
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

                if isInstrumented {
                    ExhaustLog.debug(
                        category: .reducer,
                        event: "relax_round_perturbation_accepted",
                        metadata: ["seq_len": "\(sequence.count)"]
                    )
                }
                break
            }

            materializationsUsed += 1
            if collectStats {
                stats.totalMaterializations += 1
            }
        }

        guard perturbationAccepted else {
            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "relax_round_no_perturbation",
                    metadata: [:]
                )
            }
            return false
        }

        // Exploitation: rebuild graph and run full source loop on the perturbed state.
        graph = rebuildGraph(from: tree, replacing: graph, stats: &stats)
        var exploitSources = CandidateSourceBuilder.buildSources(from: graph)

        if isInstrumented {
            ExhaustLog.debug(
                category: .reducer,
                event: "relax_round_exploitation_start",
                metadata: [
                    "seq_len": "\(sequence.count)",
                    "sources": "\(exploitSources.count)",
                ]
            )
        }

        var relaxCache = Set<UInt64>()
        while true {
            guard let sourceIndex = highestPrioritySourceIndex(exploitSources) else {
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

            let warmStarts = extractWarmStarts(from: graph)
            let exploitScope = EncoderInput(
                transformation: exploitTransformation,
                baseSequence: sequence,
                tree: tree,
                graph: graph,
                warmStartRecords: warmStarts
            )

            var exploitEncoder = selectEncoder(for: exploitTransformation.operation)
            let outcome = try runProbeLoop(
                encoder: &exploitEncoder,
                scope: exploitScope,
                graph: graph,
                sequence: &sequence,
                tree: &tree,
                output: &output,
                gen: gen,
                property: property,
                rejectCache: &relaxCache,
                stats: &stats,
                collectStats: collectStats,
                isInstrumented: isInstrumented
            )

            let convergence = exploitEncoder.convergenceRecords
            if convergence.isEmpty == false {
                graph.recordConvergence(byNodeID: convergence)
            }

            if outcome.accepted {
                if outcome.requiresRebuild {
                    graph = rebuildGraph(from: tree, replacing: graph, stats: &stats)
                    exploitSources = CandidateSourceBuilder.buildSources(from: graph)
                } else if outcome.requiresSourceRebuild {
                    exploitSources = CandidateSourceBuilder.buildSources(from: graph)
                }
            }
        }

        if sequence.shortLexPrecedes(checkpointSequence) {
            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "relax_round_committed",
                    metadata: [
                        "old_seq_len": "\(checkpointSequence.count)",
                        "new_seq_len": "\(sequence.count)",
                    ]
                )
            }
            return true
        }

        // Rollback: restore checkpoint state.
        sequence = checkpointSequence
        tree = checkpointTree
        output = checkpointOutput
        graph = rebuildGraph(from: tree, replacing: graph, stats: &stats)
        transferConvergence(checkpointConvergence, to: graph)

        if isInstrumented {
            ExhaustLog.debug(
                category: .reducer,
                event: "relax_round_rolled_back",
                metadata: ["seq_len": "\(sequence.count)"]
            )
        }
        return false
    }

    // swiftlint:enable function_parameter_count

    // MARK: - Perturbation Candidate Construction

    /// Builds structural perturbation candidates from replacement scopes without the shortlex gate.
    ///
    /// Generates candidates from three sources:
    /// - Branch pivots with leaves zeroed (crosses the two-step barrier where the minimized pivot passes but zeroed values under the new branch fail)
    /// - Self-similar substitutions where donor is larger than target (normally rejected by shortlex because the candidate grows)
    /// - Descendant promotions (these should already be tried by the standard encoder, but may have been rejected by shortlex due to expanded depth-0 leaves)
    ///
    /// Candidates are ordered by sequence length (shorter first) so the exploitation phase starts from the most promising perturbation.
    private static func buildRelaxCandidates(
        sequence: ChoiceSequence,
        graph: some ReadOnlyChoiceGraph
    ) -> [ChoiceSequence] {
        var candidates: [ChoiceSequence] = []

        for scope in ReplacementQuery.build(graph: graph) {
            switch scope {
            case let .branchPivot(pivotScope):
                if let candidate = buildUnguardedBranchPivot(
                    scope: pivotScope,
                    sequence: sequence,
                    graph: graph
                ) {
                    candidates.append(candidate)
                }

            case let .selfSimilar(selfSimilarScope):
                if let candidate = buildUnguardedSelfSimilar(
                    scope: selfSimilarScope,
                    sequence: sequence,
                    graph: graph
                ) {
                    candidates.append(candidate)
                }

            case let .descendantPromotion(promotionScope):
                if let candidate = buildUnguardedDescendantPromotion(
                    scope: promotionScope,
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

    /// Builds a branch pivot candidate with all target branch leaves zeroed. No shortlex gate.
    private static func buildUnguardedBranchPivot(
        scope: BranchPivotScope,
        sequence: ChoiceSequence,
        graph: some ReadOnlyChoiceGraph
    ) -> ChoiceSequence? {
        guard scope.pickNodeID < graph.nodes.count else { return nil }
        guard case let .pick(pickMetadata) = graph.nodes[scope.pickNodeID].kind else { return nil }
        guard let pickRange = graph.nodes[scope.pickNodeID].positionRange else { return nil }

        let elements = pickMetadata.branchElements
        guard pickMetadata.selectedChildIndex < elements.count else { return nil }

        guard let targetElementIndex = elements.firstIndex(where: { element in
            switch element {
            case let .branch(_, _, candidateID, _, _):
                candidateID == scope.targetBranchID
            default:
                false
            }
        }) else { return nil }

        let minimizedTarget = GraphStructuralEncoder.minimizingLeaves(in: elements[targetElementIndex])
        let targetContent = ChoiceSequence.flatten(.selected(minimizedTarget))

        var replacement: [ChoiceSequenceValue] = []
        replacement.reserveCapacity(targetContent.count + 3)
        replacement.append(.group(true))
        replacement.append(.branch(.init(id: scope.targetBranchID, branchCount: pickMetadata.branchCount)))
        replacement.append(contentsOf: targetContent)
        replacement.append(.group(false))

        var candidate = sequence
        candidate.replaceSubrange(pickRange.lowerBound ... pickRange.upperBound, with: replacement)
        return candidate
    }

    /// Builds a self-similar substitution candidate without shortlex gate.
    private static func buildUnguardedSelfSimilar(
        scope: SelfSimilarReplacementScope,
        sequence: ChoiceSequence,
        graph: some ReadOnlyChoiceGraph
    ) -> ChoiceSequence? {
        guard let targetRange = graph.nodes[scope.targetNodeID].positionRange,
              let donorRange = graph.nodes[scope.donorNodeID].positionRange
        else { return nil }
        let donorEntries = Array(sequence[donorRange.lowerBound ... donorRange.upperBound])
        let expanded = GraphStructuralEncoder.expandDepthZeroLeaves(
            donorEntries,
            donorNodeID: scope.donorNodeID,
            donorRangeStart: donorRange.lowerBound,
            graph: graph
        )
        var candidate = sequence
        candidate.replaceSubrange(targetRange.lowerBound ... targetRange.upperBound, with: expanded)
        guard candidate != sequence else { return nil }
        return candidate
    }

    /// Builds a descendant promotion candidate without shortlex gate.
    private static func buildUnguardedDescendantPromotion(
        scope: DescendantPromotionScope,
        sequence: ChoiceSequence,
        graph: some ReadOnlyChoiceGraph
    ) -> ChoiceSequence? {
        guard let ancestorRange = graph.nodes[scope.ancestorPickNodeID].positionRange,
              let descendantRange = graph.nodes[scope.descendantPickNodeID].positionRange
        else { return nil }
        let descendantEntries = Array(sequence[descendantRange.lowerBound ... descendantRange.upperBound])
        let expanded = GraphStructuralEncoder.expandDepthZeroLeaves(
            descendantEntries,
            donorNodeID: scope.descendantPickNodeID,
            donorRangeStart: descendantRange.lowerBound,
            graph: graph
        )
        var candidate = sequence
        candidate.replaceSubrange(ancestorRange.lowerBound ... ancestorRange.upperBound, with: expanded)
        guard candidate != sequence else { return nil }
        return candidate
    }
}
