//
//  ScopedReductionRunner+Dispatch.swift
//  Exhaust
//

// MARK: - Dispatch

extension ScopedReductionRunner {
    /// How a dispatch loop selects and follows up its passes.
    enum DispatchPolicy {
        /// Ordinary cycles: dispatch gates, scope rejections, classification, and rematerialization all apply, and rebuilds keep whatever sources survive.
        case main
        /// Relax round exploitation: none of the main policy's dispatch decisions, no operations that need the generator, and every rebuild prepares all sources again.
        case exploitation
    }

    /// What dispatch does with one encoder scope.
    enum DispatchDecision: Equatable {
        case skip
        case classifyBind(bindNodeID: Int, upstreamLeafNodeID: Int, fingerprint: UInt64)
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
        let encoderScope: AnyEncoderScope
        let boundValueFingerprint: UInt64?
        let report: ScopedPassReport
    }

    // MARK: - Dispatch Loop

    /// Dispatches the sources' scopes in priority order until every source is exhausted or the deadline passes.
    mutating func dispatchCycle(policy: DispatchPolicy = .main) -> PhaseOutcome {
        while true {
            let encoderScope: AnyEncoderScope
            let boundValueFingerprint: UInt64?
            switch selectDispatch(policy: policy) {
                case .skip:
                    chargeElapsed(to: .dispatch)
                    continue
                case let .end(outcome):
                    chargeElapsed(to: .dispatch)
                    return outcome
                case let .dispatch(selected, fingerprint):
                    encoderScope = selected
                    boundValueFingerprint = fingerprint
            }

            let pass = runPass(encoderScope, boundValueFingerprint: boundValueFingerprint)
            let action = applyPassPolicy(pass)
            chargeElapsed(to: .passApply)
            switch (policy, action) {
                case (.main, _) where deadline.isExpired:
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
        /// The step consumed an encoder scope, or an exhausted source, without running a pass.
        case skip
        case end(PhaseOutcome)
        case dispatch(AnyEncoderScope, boundValueFingerprint: UInt64?)
    }

    /// Selects the highest-priority source's next encoder scope and resolves it under `policy`.
    private mutating func selectDispatch(policy: DispatchPolicy) -> DispatchSelection {
        guard deadline.isExpired == false else {
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
        guard deadline.isExpired == false else {
            return .end(.deadline)
        }
        let encoderScope = priced.encoderScope
        guard isEncoderEnabled(encoderScope.encoder.name) else {
            return .skip
        }

        switch policy {
            case .exploitation:
                let typed = encoderScope.typed
                guard typed.isValid(in: graph), typed.encoder.requiresGenerator == false else {
                    return .skip
                }
                return .dispatch(encoderScope, boundValueFingerprint: nil)
            case .main:
                switch resolveDispatch(encoderScope) {
                    case .skip:
                        return .skip
                    case .deadline:
                        return .end(.deadline)
                    case let .dispatch(fingerprint):
                        return .dispatch(encoderScope, boundValueFingerprint: fingerprint)
                }
        }
    }

    /// The main policy's resolution of one encoder scope, including the classification and rematerialization effects it can trigger.
    private enum Resolution {
        case skip
        case deadline
        case dispatch(boundValueFingerprint: UInt64?)
    }

    private mutating func resolveDispatch(_ encoderScope: AnyEncoderScope) -> Resolution {
        let typed = encoderScope.typed
        if case .demotedAfterRejects = typed.gate,
           tuning.migrationDemotionThreshold > 0,
           consecutiveRejectsByEncoder[typed.encoder.name, default: 0] >= tuning.migrationDemotionThreshold
        {
            return .skip
        }

        var decision = evaluateDispatch(encoderScope)

        if case let .classifyBind(bindNodeID, upstreamLeafNodeID, fingerprint) = decision {
            let classificationMaterializations = graph.classifyBind(
                at: bindNodeID,
                gen: generator,
                baseSequence: incumbent.sequence,
                fallbackTree: incumbent.tree,
                upstreamLeafNodeID: upstreamLeafNodeID
            )
            if collectStats {
                stats.recordMaterializations(classificationMaterializations, at: .classification)
            }
            guard deadline.isExpired == false else {
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
    func evaluateDispatch(_ encoderScope: AnyEncoderScope) -> DispatchDecision {
        let typed = encoderScope.typed
        guard typed.isValid(in: graph) else {
            return .skip
        }

        if scopeRejectionCache.isRejected(encoderScope, sequence: incumbent.sequence, graph: graph) {
            return .skip
        }

        switch typed.gate {
            case let .bindClassification(bindNodeID, upstreamLeafNodeID):
                guard bindNodeID < graph.nodes.count,
                      case let .bind(bindMetadata) = graph.nodes[bindNodeID].kind
                else {
                    return .skip
                }
                let fingerprint = bindMetadata.fingerprint

                switch gate.shouldDispatch(fingerprint: fingerprint, anyAcceptedThisCycle: anyAccepted) {
                    case .skip:
                        return .skip
                    case .classifyFirst:
                        guard let cached = graph.bindClassifications[fingerprint] else {
                            return .classifyBind(bindNodeID: bindNodeID, upstreamLeafNodeID: upstreamLeafNodeID, fingerprint: fingerprint)
                        }
                        if cached.topology != .identical || cached.liftability != .both {
                            return .skip
                        }
                    case .dispatch:
                        break
                }

                return .readyToDispatch(boundValueFingerprint: fingerprint)
            case let .stalledBindInner(leafNodeID):
                guard anyAccepted == false,
                      ScopedStagedJointQuery.isStalledBindInner(bindInnerLeafNodeID: leafNodeID, graph: graph, isFruitlessBind: gate.isFruitless)
                else {
                    return .skip
                }
            case .open, .demotedAfterRejects:
                break
        }

        if graphIsStripped, typed.encoder.isPathChanging {
            return .rematerialize
        }

        return .readyToDispatch(boundValueFingerprint: nil)
    }

    // MARK: - Pass

    /// Runs the encoder's reducer for one scope in its own interpreter execution, seeded from the runner's state, and adopts the incumbent, graph, and cache it returns.
    ///
    /// - Parameters:
    ///   - boundValueFingerprint: The bind's fingerprint for a scope behind a bind classification gate, which supplies the decayed budget and first-dispatch probe cap.
    ///   - usesWarmStarts: Whether value searches start from the graph's convergence records. Post-cycle passes start fresh.
    ///   - checksDeadline: False for the final reorder pass, which always runs to completion.
    mutating func runPass(
        _ encoderScope: AnyEncoderScope,
        boundValueFingerprint: UInt64?,
        usesWarmStarts: Bool = true,
        checksDeadline: Bool = true
    ) -> PassRecord {
        let typed = encoderScope.typed
        var input = ScopedEncoderInput(
            baseSequence: incumbent.sequence,
            tree: incumbent.tree,
            graph: graph,
            warmStartRecords: usesWarmStarts ? graph.convergenceStore : [:],
            tuning: tuning
        )
        if case .bindClassification = typed.gate {
            let fingerprint = boundValueFingerprint ?? 0
            input.dispatchBudget = ScopedDispatchBudget(
                upstreamBudget: gate.decayedBudget(fingerprint: fingerprint),
                totalProbeCap: gate.isFirstDispatch(fingerprint: fingerprint) ? tuning.composedFirstDispatchProbeCap : 0
            )
        }
        let scopedReducer = typed.reducer(input: input)
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
        let result = ScopedReductionInterpreter.reduce(
            scopedReducer,
            context: ScopedReductionInterpreter.Context(
                incumbent: incumbent,
                graph: executionGraph,
                rejectCache: executionRejectCache,
                decoder: decoder,
                encoder: typed.encoder,
                isInstrumented: isInstrumented,
                deadline: checksDeadline ? deadline : .none,
                timingMark: collectStats ? timingMark : nil
            )
        )
        chargeProbing(result.probeTiming)
        incumbent = result.incumbent
        graph = result.graph
        rejectCache = result.rejectCache

        return PassRecord(
            encoderScope: encoderScope,
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

    // MARK: - Pass Policy

    /// Applies a completed pass to the runner's memory: convergence, coupling, the gate, migration demotion, unresolved replacements, statistics, acceptance flags, and scope rejections.
    ///
    /// Shared by dispatched and post-cycle passes. The returned action lets each caller choose its own rebuild.
    ///
    /// - Parameter appliedPasses: Passes this record stands for. The staged joint encoder's reducer runs one search per arity, and each counts as a pass, as each stage did in its own session.
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

        let typed = pass.encoderScope.typed
        if case .demotedAfterRejects = typed.gate {
            let name = typed.encoder.name
            consecutiveRejectsByEncoder[name] = report.anyAccepted ? 0 : consecutiveRejectsByEncoder[name, default: 0] + 1
        }

        if hadUnresolvedReplacement == false, report.searchReport.hadUnresolvedReplacement {
            hadUnresolvedReplacement = true
        }

        if report.buildOutcomes.isEmpty == false {
            stats.compositionBuildOutcomes[pass.encoderScope.encoder.name, default: [:]].merge(report.buildOutcomes, uniquingKeysWith: +)
        }

        if collectStats {
            recordPassStatistics(pass)
        }

        if collectDiagnostics {
            recordDispatch(pass)
        }

        ScopedReductionLog.reducer("graph_encoder_pass", isInstrumented: isInstrumented, metadata: [
            "encoder": pass.encoderScope.encoder.name.rawValue, "probes": "\(report.counts.emitted)",
            "accepted": "\(report.counts.accepted)", "cache_hits": "\(report.counts.rejectedByCache)",
            "decoder_rejects": "\(report.counts.decoderRejections)", "seq_len": "\(incumbent.sequence.count)",
        ])

        let action: PostAcceptanceAction = report.anyAccepted && (report.anyRequiresRebuild || typed.encoder.rebuildsAfterAcceptance)
            ? .rebuildAndResume
            : .continueDispatching

        if report.anyAccepted {
            anyAccepted = true
            anyAcceptanceEverOccurred = true
        }

        switch action {
            case .continueDispatching:
                if report.anyAccepted == false {
                    scopeRejectionCache.recordRejection(pass.encoderScope, sequence: incumbent.sequence, graph: graph)
                }
            case .rebuildAndResume:
                gate.clearFruitless()
        }
        return action
    }

    // MARK: - Rebuilds

    /// Rebuilds the graph after an accepting pass and keeps whatever sources the diff allows: a value-only change keeps the structural families; a leaf-kind change keeps reusable structural families, rebuilds permutation and value families, and clears the scope cache; anything else rebuilds every family and clears the scope cache. Convergence the encoder reports its acceptance invalidated is cleared as well.
    mutating func rebuildAfterPass(_ pass: PassRecord) {
        let invalidatedRange = pass.encoderScope.typed.convergenceInvalidatedByAcceptance(in: graph)

        let graphBefore = graph
        let graphStart = MonotonicClock.nanoseconds()
        let diff = rebuildAndUpdateGraph(valueGuardExemptNodeIDs: Self.valueGuardExemptNodeIDs(of: pass))
        graphIsStripped = pass.report.latestTreeIsStripped

        if let invalidatedRange {
            graph.clearConvergence(inPositionRange: invalidatedRange)
        }
        let graphEnd = MonotonicClock.nanoseconds()

        if diff.canReuseStructuralSources {
            sources = sources.filter { $0.isValueDependent == false }
                + ScopedSource.prepareValueSources(from: graph, deferBindInner: deferBindInner, tuning: tuning)
            ScopedReductionLog.reducer("graph_value_only_rebuild", isInstrumented: isInstrumented, metadata: [
                "seq_len": "\(incumbent.sequence.count)", "nodes": "\(graph.nodes.count)", "sources": "\(sources.count)",
            ])
        } else if diff.canReuseStructuralSourcesExceptPermutation {
            scopeRejectionCache.clear()
            sources = sources.filter(\.canReuseAfterLeafKindChange)
                + ScopedSource.preparePermutationSources(from: graph)
                + ScopedSource.prepareValueSources(from: graph, deferBindInner: deferBindInner, tuning: tuning)
            ScopedReductionLog.reducer("graph_leaf_kind_rebuild", isInstrumented: isInstrumented, metadata: [
                "seq_len": "\(incumbent.sequence.count)", "nodes": "\(graph.nodes.count)", "sources": "\(sources.count)",
            ])
        } else {
            scopeRejectionCache.clear()
            sources = prepareAllSources(previousGraph: graphBefore)
            ScopedReductionLog.reducer("graph_structural_rebuild", isInstrumented: isInstrumented, metadata: [
                "seq_len": "\(incumbent.sequence.count)", "nodes": "\(graph.nodes.count)", "sources": "\(sources.count)",
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
        sources = deadline.isExpired ? [] : prepareExploitationSources()
    }

    /// Every family over the current graph, with no bind-inner deferral.
    func prepareExploitationSources() -> [ScopedSource] {
        ScopedSource.prepareStructuralSources(from: graph)
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
        stats.record(report.counts, for: pass.encoderScope.encoder.name)
        for searchCounts in report.searchCounts {
            guard let arity = searchCounts.stagedJointArity else {
                continue
            }
            stats.numericSearchCountsByArity[arity, default: ReductionProbeCounts()].merge(searchCounts.counts)
        }
        if report.liftAttempts > 0 {
            stats.recordMaterializations(report.liftAttempts, at: .lift)
            stats.liftAttemptsByEncoder[pass.encoderScope.encoder.name, default: 0] += report.liftAttempts
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
            encoderName: pass.encoderScope.encoder.name,
            probeCount: report.counts.emitted,
            acceptCount: report.counts.accepted,
            cacheHitCount: report.counts.rejectedByCache,
            decoderRejectCount: report.counts.decoderRejections,
            sequenceLengthDelta: dispatchBaselineLength - incumbent.sequence.count,
            targetDistanceDelta: distanceDelta,
            boundValueFingerprint: pass.boundValueFingerprint,
            composedUpstreamLifts: nil,
            bindClassification: pass.boundValueFingerprint.flatMap { graph.bindClassifications[$0] }
        ))

        if report.anyAccepted, case .redistribution = pass.encoderScope {
            stats.redistributionAcceptanceNodeIDs.formUnion(report.acceptedLeafNodeIDs)
        }
    }
}
