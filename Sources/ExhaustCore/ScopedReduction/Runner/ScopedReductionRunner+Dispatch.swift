//
//  ScopedReductionRunner+Dispatch.swift
//  Exhaust
//

// MARK: - Dispatch

extension ScopedReductionRunner {
    /// How a dispatch loop selects and follows up its passes.
    enum DispatchPolicy {
        /// Ordinary cycles: the bound value gate, scope rejections, migration demotion, classification, and rematerialization all apply, and rebuilds keep whatever sources survive.
        case main
        /// Relax round exploitation: none of the main policy's dispatch decisions, no operations that need the generator, and every rebuild prepares all sources again.
        case exploitation
    }

    /// What dispatch does with one opportunity.
    enum DispatchDecision: Equatable {
        case skip
        case classifyBind(bindNodeID: Int, fingerprint: UInt64)
        case rematerialize
        case readyToDispatch(boundValueFingerprint: UInt64?)
    }

    /// What follows a completed pass.
    enum PostAcceptanceAction: Equatable {
        case continueDispatching
        case rebuildAndResume
    }

    /// One completed pass: what ran, and what its execution observed.
    struct PassRecord {
        let opportunity: ScopedOpportunity
        let encoderName: EncoderName
        let boundValueFingerprint: UInt64?
        let report: ScopedPassReport
    }

    // MARK: - Dispatch Loop

    /// Dispatches the sources' scopes in priority order until every source is exhausted or the deadline passes.
    mutating func dispatchCycle(policy: DispatchPolicy = .main) -> PhaseOutcome {
        while true {
            let opportunity: ScopedOpportunity
            let boundValueFingerprint: UInt64?
            switch selectDispatch(policy: policy) {
                case .skip:
                    chargeElapsed(to: .dispatch)
                    continue
                case let .end(outcome):
                    chargeElapsed(to: .dispatch)
                    return outcome
                case let .dispatch(selected, fingerprint):
                    opportunity = selected
                    boundValueFingerprint = fingerprint
            }

            let pass = runPass(opportunity, boundValueFingerprint: boundValueFingerprint)
            let action = applyPassPolicy(pass)
            chargeElapsed(to: .passApply)
            switch (policy, action) {
                case (.main, _) where isDeadlineExceeded():
                    rebuildGraphAtDeadline(after: pass)
                    chargeElapsed(to: .rebuild)
                    return .deadline
                case (.main, .rebuildAndResume):
                    rebuildAfterPass(pass)
                    chargeElapsed(to: .rebuild)
                case (.exploitation, .rebuildAndResume):
                    rebuildForExploitation(after: pass)
                    chargeElapsed(to: .rebuild)
                case (_, .continueDispatching):
                    break
            }
        }
    }

    /// What one dispatch step chose.
    private enum DispatchSelection {
        /// The step consumed an opportunity, or an exhausted source, without running a pass.
        case skip
        case end(PhaseOutcome)
        case dispatch(ScopedOpportunity, boundValueFingerprint: UInt64?)
    }

    /// Selects the highest-priority source's next opportunity and resolves it under `policy`.
    private mutating func selectDispatch(policy: DispatchPolicy) -> DispatchSelection {
        guard isDeadlineExceeded() == false else {
            return .end(.deadline)
        }
        guard let sourceIndex = ScopedSource.highestPrioritySourceIndex(&sources) else {
            return .end(.completed)
        }
        guard let priced = sources[sourceIndex].nextScope() else {
            sources.swapAt(sourceIndex, sources.count - 1)
            sources.removeLast()
            return .skip
        }
        guard isDeadlineExceeded() == false else {
            return .end(.deadline)
        }
        let opportunity = priced.opportunity
        guard isEncoderEnabled(opportunity.encoderName) else {
            return .skip
        }

        switch policy {
            case .exploitation:
                guard opportunity.isValid(in: graph), opportunity.requiresGenerator == false else {
                    return .skip
                }
                return .dispatch(opportunity, boundValueFingerprint: nil)
            case .main:
                switch resolveDispatch(opportunity) {
                    case .skip:
                        return .skip
                    case .deadline:
                        return .end(.deadline)
                    case let .dispatch(fingerprint):
                        return .dispatch(opportunity, boundValueFingerprint: fingerprint)
                }
        }
    }

    /// The main policy's resolution of one opportunity, including the classification and rematerialization effects it can trigger.
    private enum Resolution {
        case skip
        case deadline
        case dispatch(boundValueFingerprint: UInt64?)
    }

    private mutating func resolveDispatch(_ opportunity: ScopedOpportunity) -> Resolution {
        if opportunity.encoderName == .migration,
           tuning.migrationDemotionThreshold > 0,
           migrationConsecutiveRejects >= tuning.migrationDemotionThreshold
        {
            return .skip
        }

        var decision = evaluateDispatch(opportunity)

        if case let .classifyBind(bindNodeID, fingerprint) = decision {
            guard case let .boundValue(bindScope) = opportunity else {
                return .skip
            }
            let classificationMaterializations = graph.classifyBind(
                at: bindNodeID,
                gen: generator,
                baseSequence: sequence,
                fallbackTree: tree,
                upstreamLeafNodeID: bindScope.upstreamLeafNodeID
            )
            if collectStats {
                stats.recordMaterializations(classificationMaterializations, at: .classification)
            }
            guard isDeadlineExceeded() == false else {
                return .deadline
            }
            guard case let .bind(updatedMetadata) = graph.nodes[bindNodeID].kind,
                  let classification = updatedMetadata.classification
            else {
                return .skip
            }
            if classification.topology != .identical || classification.liftability != .both {
                gate.markFruitless(fingerprint)
                return .skip
            }
            decision = .readyToDispatch(boundValueFingerprint: fingerprint)
        }

        switch decision {
            case .skip, .classifyBind:
                return .skip
            case .rematerialize:
                let graphBefore = rematerializeUnselectedBranches()
                sources = prepareAllSources(previousGraph: graphBefore)
                return .skip
            case let .readyToDispatch(boundValueFingerprint):
                return .dispatch(boundValueFingerprint: boundValueFingerprint)
        }
    }

    /// Decides whether to dispatch, skip, classify a bind first, or rematerialize a stripped graph.
    func evaluateDispatch(_ opportunity: ScopedOpportunity) -> DispatchDecision {
        guard opportunity.isValid(in: graph) else {
            return .skip
        }

        if scopeRejectionCache.isRejected(opportunity, sequence: sequence, graph: graph) {
            return .skip
        }

        if case let .boundValue(bindScope) = opportunity {
            guard bindScope.bindNodeID < graph.nodes.count,
                  case let .bind(bindMetadata) = graph.nodes[bindScope.bindNodeID].kind
            else {
                return .skip
            }
            let fingerprint = bindMetadata.fingerprint

            switch gate.shouldDispatch(fingerprint: fingerprint, anyAcceptedThisCycle: anyAccepted) {
                case .skip:
                    return .skip
                case .classifyFirst:
                    guard let cached = graph.bindClassifications[fingerprint] else {
                        return .classifyBind(bindNodeID: bindScope.bindNodeID, fingerprint: fingerprint)
                    }
                    if cached.topology != .identical || cached.liftability != .both {
                        return .skip
                    }
                case .dispatch:
                    break
            }

            return .readyToDispatch(boundValueFingerprint: fingerprint)
        }

        if case let .boundExchange(exchange) = opportunity {
            guard anyAccepted == false,
                  Self.isStalledBindInner(bindInnerLeafNodeID: exchange.sourceLeafNodeID, graph: graph, gate: gate)
            else {
                return .skip
            }
        }

        if graphIsStripped, opportunity.isPathChanging {
            return .rematerialize
        }

        return .readyToDispatch(boundValueFingerprint: nil)
    }

    // MARK: - Pass

    /// Runs one scope's program in its own interpreter execution, seeded from the runner's state, and adopts the incumbent, graph, and cache it returns.
    ///
    /// - Parameters:
    ///   - boundValueFingerprint: The bind's fingerprint for a bound value scope; its gate supplies the decayed budget and first-dispatch probe cap.
    ///   - usesWarmStarts: Whether value searches start from the graph's convergence records. Post-cycle passes start fresh.
    ///   - checksDeadline: False for the final reorder pass, which always runs to completion.
    mutating func runPass(
        _ opportunity: ScopedOpportunity,
        boundValueFingerprint: UInt64?,
        usesWarmStarts: Bool = true,
        checksDeadline: Bool = true
    ) -> PassRecord {
        let input = ScopedEncoderInput(
            baseSequence: sequence,
            tree: tree,
            graph: graph,
            warmStartRecords: usesWarmStarts ? graph.convergenceStore : [:]
        )
        let encoder = opportunity.encoder(tuning: tuning)
        let program = reducer(for: opportunity, input: input, boundValueFingerprint: boundValueFingerprint)
        if let boundValueFingerprint {
            gate.markDispatched(boundValueFingerprint)
        }

        captureDispatchBaseline()
        chargeElapsed(to: .dispatch)
        // Moved rather than copied, so the runner holds no second reference while the execution edits them, and the first edit does not copy their storage.
        var executionGraph = Self.vacatedGraph
        swap(&executionGraph, &graph)
        var executionRejectCache: Set<UInt64> = []
        swap(&executionRejectCache, &rejectCache)
        let result = ScopedReductionInterpreter.run(
            program,
            context: ScopedReductionInterpreter.Context(
                incumbent: ScopedCounterexample(
                    sequence: sequence,
                    tree: tree,
                    output: ScopedOutputHandle(value: output)
                ),
                graph: executionGraph,
                rejectCache: executionRejectCache,
                decoder: decoder,
                encoderName: encoder.name,
                isInstrumented: isInstrumented,
                deadlineCheck: checksDeadline ? makeDeadlineCheck() : nil,
                timingMark: collectStats ? timingMark : nil
            )
        )
        chargeProbing(result.probeTiming)
        sequence = result.incumbent.sequence
        tree = result.incumbent.tree
        output = result.incumbent.output.value
        graph = result.graph
        rejectCache = result.rejectCache

        return PassRecord(
            opportunity: opportunity,
            encoderName: encoder.name,
            boundValueFingerprint: boundValueFingerprint,
            report: result.report
        )
    }

    /// Stands in for the graph while a pass's execution owns it. Holds no storage.
    private static let vacatedGraph = ChoiceGraph(
        nodes: [],
        containmentEdges: [],
        dependencyEdges: [],
        selfSimilarityGroups: [:],
        liveNodeIDs: [],
        leafNodes: [],
        characterLeafNodes: [],
        topologicalOrder: [],
        dependencyAdjacency: []
    )

    /// Builds the opportunity's reducer. A bound value scope takes its upstream budget and probe cap from the gate.
    private func reducer(
        for opportunity: ScopedOpportunity,
        input: ScopedEncoderInput,
        boundValueFingerprint: UInt64?
    ) -> ScopedReducer {
        switch opportunity {
            case let .boundValue(bindScope):
                let fingerprint = boundValueFingerprint ?? 0
                return ScopedBoundValueEncoder(tuning: tuning).reducer(
                    ScopedBoundValueEncoder.Scope(
                        bindScope: bindScope,
                        upstreamBudget: gate.decayedBudget(fingerprint: fingerprint),
                        totalProbeCap: gate.isFirstDispatch(fingerprint: fingerprint) ? tuning.composedFirstDispatchProbeCap : 0
                    ),
                    input: input
                )
            case let .boundExchange(scope):
                return ScopedBoundExchangeEncoder(tuning: tuning).reducer(scope, input: input)
            case let .bindPivot(scope):
                return ScopedBindPivotEncoder(tuning: tuning).reducer(scope, input: input)
            case let .depthCollapse(scope):
                return ScopedDepthCollapseEncoder(tuning: tuning).reducer(scope, input: input)
            case let .laneCollapse(scope):
                return ScopedLaneCollapseEncoder(tuning: tuning).reducer(scope, input: input)
            case let .valueSearch(scope):
                return ScopedValueSearchEncoder(tuning: tuning).reducer(scope, input: input)
            case let .redistribution(scope):
                return ScopedRedistributionEncoder(tuning: tuning).reducer(scope, input: input)
            case let .lockstep(scope):
                return ScopedLockstepEncoder(tuning: tuning).reducer(scope, input: input)
            case let .relation(scope):
                return ScopedRelationEncoder(tuning: tuning).reducer(scope, input: input)
            case let .stagedJoint(scope):
                return ScopedStagedJointEncoder(tuning: tuning).reducer(scope, input: input)
            case let .removal(scope):
                return ScopedRemovalEncoder(tuning: tuning).reducer(scope, input: input)
            case let .substitution(scope):
                return ScopedSubstitutionEncoder(tuning: tuning).reducer(scope, input: input)
            case let .branchPivot(scope):
                return ScopedBranchPivotEncoder(tuning: tuning).reducer(scope, input: input)
            case let .migration(scope):
                return ScopedMigrationEncoder(tuning: tuning).reducer(scope, input: input)
            case let .swap(scope):
                return ScopedSwapEncoder(tuning: tuning).reducer(scope, input: input)
            case let .reorder(scope):
                return ScopedReorderEncoder(tuning: tuning).reducer(scope, input: input)
        }
    }

    // MARK: - Pass Policy

    /// Applies a completed pass to the runner's memory: convergence, coupling, the gate, migration demotion, unresolved replacements, statistics, acceptance flags, and scope rejections.
    ///
    /// Shared by dispatched and post-cycle passes. The returned action lets each caller choose its own rebuild.
    ///
    /// - Parameter appliedPasses: Passes this record stands for. A staged joint program runs one search per arity, and each counts as a pass, as each stage did in its own session.
    @discardableResult
    mutating func applyPassPolicy(_ pass: PassRecord, appliedPasses: Int = 1) -> PostAcceptanceAction {
        let report = pass.report
        let convergenceRecords = report.searchReport.convergenceRecords
        passCounter += appliedPasses
        var valueMotionNodes: Set<Int> = []

        if convergenceRecords.isEmpty == false {
            let motion = graph.recordConvergence(
                byNodeID: convergenceRecords,
                rebuildGeneration: stats.graphStats.fullGraphRebuilds
            )
            valueMotionNodes = motion.valueMotionNodeIDs
            if collectDiagnostics {
                recordFloorMotion(motion, convergedNodeIDs: Array(convergenceRecords.keys))
            }
        }

        if isEncoderEnabled(.stagedJointSearch), tuning.stagedJointProbeBudget > 0 {
            couplingTracker.observe(
                motionNodes: valueMotionNodes,
                convergedNodes: Array(convergenceRecords.keys),
                changedNodes: report.acceptedLeafNodeIDs,
                pass: passCounter,
                graph: &graph
            )
        }

        if collectDiagnostics, report.acceptedLeafNodeIDs.isEmpty == false {
            valueChangeLog.append((passIndex: passCounter, nodeIDs: report.acceptedLeafNodeIDs))
        }

        if let fingerprint = pass.boundValueFingerprint {
            gate.recordOutcome(fingerprint: fingerprint, accepted: report.anyAccepted)
        }

        if pass.encoderName == .migration {
            migrationConsecutiveRejects = report.anyAccepted ? 0 : migrationConsecutiveRejects + 1
        }

        if hadUnresolvedReplacement == false, report.searchReport.hadUnresolvedReplacement {
            hadUnresolvedReplacement = true
        }

        boundValueBuildOutcomes.merge(report.boundValueBuildOutcomes, uniquingKeysWith: +)
        boundValueLiftAttempts += report.boundValueLiftAttempts

        if collectStats {
            recordPassStatistics(pass)
        }

        if collectDiagnostics {
            recordDispatch(pass)
        }

        Self.log("graph_encoder_pass", isInstrumented: isInstrumented, metadata: [
            "encoder": pass.encoderName.rawValue, "probes": "\(report.counts.emitted)",
            "accepted": "\(report.counts.accepted)", "cache_hits": "\(report.counts.rejectedByCache)",
            "decoder_rejects": "\(report.counts.decoderRejections)", "seq_len": "\(sequence.count)",
        ])

        let isBoundValue = switch pass.opportunity {
            case .boundValue:
                true
            default:
                false
        }
        let action: PostAcceptanceAction = report.anyAccepted && (report.anyRequiresRebuild || isBoundValue)
            ? .rebuildAndResume
            : .continueDispatching

        if report.anyAccepted {
            anyAccepted = true
            anyAcceptanceEverOccurred = true
        }

        switch action {
            case .continueDispatching:
                if report.anyAccepted == false {
                    scopeRejectionCache.recordRejection(pass.opportunity, sequence: sequence, graph: graph)
                }
            case .rebuildAndResume:
                gate.clearFruitless()
        }
        return action
    }

    // MARK: - Rebuilds

    /// Rebuilds the graph after an accepting pass and keeps whatever sources the diff allows: a value-only change keeps the structural families; a leaf-kind change keeps reusable structural families, rebuilds permutation and value families, and clears the scope cache; anything else rebuilds every family and clears the scope cache. A bound value pass also clears convergence in the bind's bound range, which its lifts invalidated.
    mutating func rebuildAfterPass(_ pass: PassRecord) {
        var boundPositionRange: ClosedRange<Int>?
        if case let .boundValue(bindScope) = pass.opportunity,
           bindScope.bindNodeID < graph.nodes.count,
           case let .bind(bindMetadata) = graph.nodes[bindScope.bindNodeID].kind,
           graph.nodes[bindScope.bindNodeID].children.count > bindMetadata.boundChildIndex
        {
            let boundChildID = graph.nodes[bindScope.bindNodeID].children[bindMetadata.boundChildIndex]
            boundPositionRange = graph.nodes[boundChildID].positionRange
        }

        let graphBefore = graph
        let graphStart = MonotonicClock.nanoseconds()
        let diff = rebuildAndUpdateGraph(valueGuardExemptNodeIDs: Self.valueGuardExemptNodeIDs(of: pass))
        graphIsStripped = pass.report.latestTreeIsStripped

        if let boundRange = boundPositionRange {
            graph.clearConvergence(inPositionRange: boundRange)
        }
        let graphEnd = MonotonicClock.nanoseconds()

        if diff.canReuseStructuralSources {
            sources = sources.filter { $0.isValueDependent == false }
                + ScopedSource.prepareValueSources(from: graph, deferBindInner: deferBindInner, tuning: tuning)
            Self.log("graph_value_only_rebuild", isInstrumented: isInstrumented, metadata: [
                "seq_len": "\(sequence.count)", "nodes": "\(graph.nodes.count)", "sources": "\(sources.count)",
            ])
        } else if diff.canReuseStructuralSourcesExceptPermutation {
            scopeRejectionCache.clear()
            sources = sources.filter(\.canReuseAfterLeafKindChange)
                + ScopedSource.preparePermutationSources(from: graph, tuning: tuning)
                + ScopedSource.prepareValueSources(from: graph, deferBindInner: deferBindInner, tuning: tuning)
            Self.log("graph_leaf_kind_rebuild", isInstrumented: isInstrumented, metadata: [
                "seq_len": "\(sequence.count)", "nodes": "\(graph.nodes.count)", "sources": "\(sources.count)",
            ])
        } else {
            scopeRejectionCache.clear()
            sources = prepareAllSources(previousGraph: graphBefore)
            Self.log("graph_structural_rebuild", isInstrumented: isInstrumented, metadata: [
                "seq_len": "\(sequence.count)", "nodes": "\(graph.nodes.count)", "sources": "\(sources.count)",
            ])
        }
        let sourceEnd = MonotonicClock.nanoseconds()

        if collectStats {
            stats.stepTimings.rebuildGraphNanoseconds += graphEnd - graphStart
            stats.stepTimings.rebuildSourceNanoseconds += sourceEnd - graphEnd
        }

        valueChangeLog = []
        lastConvergencePass = [:]
    }

    /// Rebuilds the graph and every source without updating stripped-graph state or clearing diagnostic history.
    mutating func rebuildForExploitation(after pass: PassRecord) {
        rebuildAndUpdateGraph(valueGuardExemptNodeIDs: Self.valueGuardExemptNodeIDs(of: pass))
        sources = isDeadlineExceeded() ? [] : prepareExploitationSources()
    }

    /// Every family over the current graph, with no bind-inner deferral.
    func prepareExploitationSources() -> [ScopedSource] {
        ScopedSource.prepareStructuralSources(from: graph, tuning: tuning)
            + ScopedSource.prepareValueSources(from: graph, deferBindInner: false, tuning: tuning)
    }

    /// At the deadline, an accepted pass that needs a rebuild rebuilds only the graph, for the final reorder and stall diagnostics.
    mutating func rebuildGraphAtDeadline(after pass: PassRecord) {
        guard pass.report.anyAccepted, pass.report.anyRequiresRebuild else {
            return
        }
        rebuildAndUpdateGraph(valueGuardExemptNodeIDs: Self.valueGuardExemptNodeIDs(of: pass))
        graphIsStripped = pass.report.latestTreeIsStripped
    }

    // MARK: - Helpers

    /// Leaves that accepted in the pass hold stale values in the old graph, because reshaping and continuing passes skip the in-place write, so their records transfer without the value guard.
    static func valueGuardExemptNodeIDs(of pass: PassRecord) -> Set<Int> {
        pass.report.acceptedLeafNodeIDs.union(pass.report.searchReport.convergenceRecords.keys)
    }

    private mutating func recordPassStatistics(_ pass: PassRecord) {
        let report = pass.report
        stats.record(report.counts, for: pass.encoderName)
        for searchCounts in report.searchCounts {
            guard case let .stagedJoint(arity) = searchCounts.search else {
                continue
            }
            stats.numericSearchCountsByArity[arity, default: ReductionProbeCounts()].merge(searchCounts.counts)
        }
        switch pass.opportunity {
            case .bindPivot:
                stats.recordMaterializations(report.liftAttempts, at: .bindPivotLift)
            case .boundExchange:
                stats.recordMaterializations(report.liftAttempts, at: .boundExchangeLift)
            default:
                break
        }
    }

    /// Attributes floor motion to the values that changed since each moving node last converged. Research diagnostics only.
    private mutating func recordFloorMotion(_ motion: (structural: Int, value: Int, valueMotionNodeIDs: Set<Int>), convergedNodeIDs: [Int]) {
        for motionNodeID in motion.valueMotionNodeIDs {
            let sincePass = lastConvergencePass[motionNodeID] ?? 0
            var partnerNodes: Set<Int> = []
            for entry in valueChangeLog where entry.passIndex > sincePass {
                for changedNodeID in entry.nodeIDs where changedNodeID != motionNodeID {
                    partnerNodes.insert(changedNodeID)
                    let edge = CouplingEdge(motionNodeID: motionNodeID, changedNodeID: changedNodeID)
                    stats.couplingEdges[edge, default: 0] += 1
                }
            }
            stats.floorMotionPartnerCounts[partnerNodes.count, default: 0] += 1
        }

        stats.structuralFloorMotionEvents += motion.structural
        stats.valueFloorMotionEvents += motion.value
        stats.valueFloorMotionNodeIDs.formUnion(motion.valueMotionNodeIDs)

        for nodeID in convergedNodeIDs {
            lastConvergencePass[nodeID] = passCounter
        }
    }

    /// Appends the pass to the dispatch log. Research diagnostics only.
    private mutating func recordDispatch(_ pass: PassRecord) {
        let report = pass.report
        let distanceDelta = dispatchBaselineTargetDistance - sequenceTargetDistance()
        stats.dispatchLog.append(DispatchRecord(
            cycle: cycles,
            passIndex: passCounter,
            encoderName: pass.encoderName,
            probeCount: report.counts.emitted,
            acceptCount: report.counts.accepted,
            cacheHitCount: report.counts.rejectedByCache,
            decoderRejectCount: report.counts.decoderRejections,
            sequenceLengthDelta: dispatchBaselineLength - sequence.count,
            targetDistanceDelta: distanceDelta,
            boundValueFingerprint: pass.boundValueFingerprint,
            composedUpstreamLifts: nil,
            bindClassification: pass.boundValueFingerprint.flatMap { graph.bindClassifications[$0] }
        ))

        if report.anyAccepted, case .redistribution = pass.opportunity {
            stats.redistributionAcceptanceNodeIDs.formUnion(report.acceptedLeafNodeIDs)
        }
    }
}
