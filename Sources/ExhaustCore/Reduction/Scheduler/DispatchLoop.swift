//
//  DispatchLoop.swift
//  Exhaust
//

/// Selects dispatch and rebuild behavior without boxing the loop or capturing its host in closures.
enum DispatchPolicy {
    case main
    case exploitation
}

/// Owns candidate sources and the encode-decode continuation for one dispatch loop.
///
/// The main machine lends its core state for each step. Excursion exploitation can drive another loop with its own sources and simpler dispatch policy.
struct DispatchLoop {
    /// Selects one unit of dispatch, probing, or graph rebuilding work.
    enum SubPhase {
        case dispatch
        case probing
        case rebuild
        case done
    }

    var sources: [AnyCandidateSource] = []
    var subPhase: SubPhase = .dispatch
    var activeSession: ProbeSession?
    var pendingReport: PassReport?
    let policy: DispatchPolicy

    /// Routes to the active ``SubPhase`` sub-step.
    mutating func step(state: inout ReductionMachine) -> ReductionMachine.Transition? {
        if case .done = subPhase {
            return nil
        }
        if policy == .exploitation, state.isDeadlineExceeded() {
            return finishAtDeadline(state: &state)
        }
        switch subPhase {
            case .dispatch:
                return stepDispatch(state: &state)
            case .probing:
                return stepProbing(state: &state)
            case .rebuild:
                return stepRebuild(state: &state)
            case .done:
                return nil
        }
    }

    // MARK: - Dispatch

    /// Selects the highest-priority source, pulls the next transformation, and resolves the dispatch decision. On ``ChoiceGraphScheduler/DispatchDecision/readyToDispatch(boundValueFingerprint:)``, initializes the encoder and transitions to the ``SubPhase/probing`` sub-phase.
    private mutating func stepDispatch(state: inout ReductionMachine) -> ReductionMachine.Transition {
        guard let sourceIndex = ChoiceGraphScheduler.highestPrioritySourceIndex(sources) else {
            switch policy {
                case .main:
                    state.phase = .endCycle
                case .exploitation:
                    subPhase = .done
            }
            return .dispatched(decision: .sourceExhausted)
        }

        guard let transformation = sources[sourceIndex].next() else {
            sources.swapAt(sourceIndex, sources.count - 1)
            sources.removeLast()
            return .dispatched(decision: .sourceExhausted)
        }
        guard state.isDeadlineExceeded() == false else {
            return finishAtDeadline(state: &state)
        }

        guard state.isEncoderEnabled(transformation.operation.encoderName) else {
            return .dispatched(decision: .skipped)
        }

        if policy == .exploitation {
            guard transformation.operation.isValid(in: state.graph),
                  transformation.operation.requiresGenerator == false
            else {
                return .dispatched(decision: .skipped)
            }
            return beginProbeSession(
                transformation: transformation,
                boundValueFingerprint: nil,
                state: &state
            )
        }

        if transformation.operation.encoderName == .migration,
           state.tuning.migrationDemotionThreshold > 0,
           state.migrationConsecutiveRejects >= state.tuning.migrationDemotionThreshold
        {
            return .dispatched(decision: .skipped)
        }

        var decision = ChoiceGraphScheduler.evaluateDispatch(
            transformation: transformation,
            graph: state.graph,
            sequence: state.sequence,
            gate: state.convergence.gate,
            scopeCache: state.scopeRejectionCache,
            graphIsStripped: state.graphIsStripped,
            anyAccepted: state.anyAccepted
        )

        if case let .classifyBind(bindNodeID, fingerprint) = decision {
            guard case let .minimize(.boundValue(bindScope)) = transformation.operation else {
                return .dispatched(decision: .skipped)
            }
            let classificationMaterializations = state.graph.classifyBind(
                at: bindNodeID,
                gen: state.gen,
                baseSequence: state.sequence,
                fallbackTree: state.tree,
                upstreamLeafNodeID: bindScope.upstreamLeafNodeID
            )
            if state.collectStats {
                state.stats.recordMaterializations(classificationMaterializations, at: .classification)
            }
            guard state.isDeadlineExceeded() == false else {
                return finishAtDeadline(state: &state)
            }
            guard case let .bind(updatedMetadata) = state.graph.nodes[bindNodeID].kind,
                  let classification = updatedMetadata.classification
            else {
                return .dispatched(decision: .skipped)
            }
            if classification.topology != .identical || classification.liftability != .both {
                state.convergence.gate.markFruitless(fingerprint)
                return .dispatched(decision: .skipped)
            }
            decision = .readyToDispatch(boundValueFingerprint: fingerprint)
        }

        switch decision {
            case .skip:
                return .dispatched(decision: .skipped)

            case .classifyBind:
                return .dispatched(decision: .skipped)

            case .rematerialize:
                let graphBefore = state.rematerializeUnselectedBranches()
                sources = CandidateSourceBuilder.buildSources(from: state.graph, deferBindInner: state.convergence.deferBindInner, previousGraph: graphBefore)
                return .dispatched(decision: .rematerialized)

            case let .readyToDispatch(boundValueFingerprint):
                return beginProbeSession(
                    transformation: transformation,
                    boundValueFingerprint: boundValueFingerprint,
                    state: &state
                )
        }
    }

    // MARK: - Begin Probe Session

    private mutating func beginProbeSession(
        transformation: GraphTransformation,
        boundValueFingerprint: UInt64?,
        state: inout ReductionMachine
    ) -> ReductionMachine.Transition {
        let warmStarts = ChoiceGraphScheduler.extractWarmStarts(from: state.graph)
        let scope = EncoderInput(
            transformation: transformation,
            baseSequence: state.sequence,
            tree: state.tree,
            graph: state.graph,
            warmStartRecords: warmStarts
        )

        var encoder: EncoderDispatch
        if case let .minimize(.boundValue(bindScope)) = transformation.operation,
           let fingerprint = boundValueFingerprint
        {
            encoder = ChoiceGraphScheduler.makeBoundValueComposition(
                bindScope: bindScope,
                scope: scope,
                graph: state.graph,
                gen: state.gen,
                upstreamBudget: state.convergence.gate.decayedBudget(fingerprint: fingerprint),
                totalProbeCap: state.convergence.gate.isFirstDispatch(fingerprint: fingerprint)
                    ? state.tuning.composedFirstDispatchProbeCap
                    : 0,
                buildTally: state.boundValueBuildTally
            )
            state.convergence.gate.markDispatched(fingerprint)
        } else {
            encoder = ChoiceGraphScheduler.selectEncoder(for: transformation.operation, gen: state.gen)
        }

        encoder.start(scope: scope)

        state.captureDispatchBaseline()
        activeSession = ProbeSession(
            encoder: encoder,
            transformation: transformation,
            boundValueFingerprint: boundValueFingerprint,
            baseSequence: state.sequence,
            hasBind: state.sequence.contains { entry in
                if case .bind = entry { return true }
                return false
            }
        )

        subPhase = .probing
        return .dispatched(decision: .encoderStarted(encoder: encoder.name))
    }

    // MARK: - Probing

    /// Delegates to the active ``ProbeSession`` for one encode or decode sub-phase. On completion, applies the ``PassReport`` and routes to dispatch or rebuild.
    private mutating func stepProbing(state: inout ReductionMachine) -> ReductionMachine.Transition {
        guard let session = activeSession else {
            subPhase = .dispatch
            return .dispatched(decision: .sourceExhausted)
        }

        let result = session.step(state: &state)

        switch result {
            case let .encoded(encoder, cacheHit):
                return .encoded(encoder: encoder, cacheHit: cacheHit)

            case let .decoded(encoder, accepted):
                return .decoded(encoder: encoder, accepted: accepted)

            case .finished:
                let report = session.report()
                activeSession = nil
                pendingReport = report
                let action = state.applyPassPolicy(report)
                return routeAfterPass(action, report: report)
        }
    }

    /// Routes a completed pass, retaining its report only when the dispatch rebuild phase needs it.
    private mutating func routeAfterPass(
        _ action: ChoiceGraphScheduler.PostAcceptanceAction,
        report: PassReport
    ) -> ReductionMachine.Transition {
        switch action {
            case .continueDispatching:
                pendingReport = nil
                subPhase = .dispatch
            case .rebuildAndResume:
                subPhase = .rebuild
        }
        return .passCompleted(encoder: report.encoderName, accepted: report.anyAccepted)
    }

    // MARK: - Rebuild

    /// Rebuilds the graph from the current tree after a structural acceptance, clears stale convergence in bound subtrees when a bound value scope triggered the rebuild, and reconstructs candidate sources.
    private mutating func stepRebuild(state: inout ReductionMachine) -> ReductionMachine.Transition {
        if policy == .exploitation {
            return rebuildExploitation(state: &state)
        }
        var boundPositionRange: ClosedRange<Int>?
        if let report = pendingReport,
           case let .minimize(.boundValue(bindScope)) = report.transformation.operation,
           bindScope.bindNodeID < state.graph.nodes.count,
           case let .bind(bindMetadata) = state.graph.nodes[bindScope.bindNodeID].kind,
           state.graph.nodes[bindScope.bindNodeID].children.count > bindMetadata.boundChildIndex
        {
            let boundChildID = state.graph.nodes[bindScope.bindNodeID].children[bindMetadata.boundChildIndex]
            boundPositionRange = state.graph.nodes[boundChildID].positionRange
        }

        let latestTreeIsStripped = pendingReport?.latestTreeIsStripped ?? false

        // Leaves that accepted in the pass triggering this rebuild hold stale values in the old graph (reshape and stateful passes skip the in-place apply), so they are exempt from the transfer value guard.
        var valueGuardExemptNodeIDs: Set<Int> = []
        if let report = pendingReport {
            valueGuardExemptNodeIDs = report.acceptedLeafNodeIDs
                .union(report.convergenceRecords.keys)
        }

        let graphBefore = state.graph
        let graphStart = MonotonicClock.nanoseconds()
        let diff = state.rebuildAndUpdateGraph(valueGuardExemptNodeIDs: valueGuardExemptNodeIDs)
        state.graphIsStripped = latestTreeIsStripped

        if let boundRange = boundPositionRange {
            state.graph.clearConvergence(inPositionRange: boundRange)
        }
        let graphEnd = MonotonicClock.nanoseconds()

        if diff.canReuseStructuralSources {
            let structuralSources = sources.filter { $0.isValueDependent == false }
            sources = structuralSources
                + CandidateSourceBuilder.buildValueSources(from: state.graph, deferBindInner: state.convergence.deferBindInner)

            ChoiceGraphScheduler.logReducer("graph_value_only_rebuild", isInstrumented: state.isInstrumented, metadata: [
                "seq_len": "\(state.sequence.count)", "nodes": "\(state.graph.nodes.count)", "sources": "\(sources.count)",
            ])
        } else if diff.canReuseStructuralSourcesExceptPermutation {
            state.scopeRejectionCache.clear()
            let reusableStructuralSources = sources.filter { $0.canReuseAfterLeafKindChange }
            sources = reusableStructuralSources
                + CandidateSourceBuilder.buildPermutationSources(from: state.graph)
                + CandidateSourceBuilder.buildValueSources(
                    from: state.graph,
                    deferBindInner: state.convergence.deferBindInner
                )

            ChoiceGraphScheduler.logReducer("graph_leaf_kind_rebuild", isInstrumented: state.isInstrumented, metadata: [
                "seq_len": "\(state.sequence.count)", "nodes": "\(state.graph.nodes.count)", "sources": "\(sources.count)",
            ])
        } else {
            state.scopeRejectionCache.clear()
            sources = CandidateSourceBuilder.buildSources(from: state.graph, deferBindInner: state.convergence.deferBindInner, previousGraph: graphBefore)

            ChoiceGraphScheduler.logReducer("graph_structural_rebuild", isInstrumented: state.isInstrumented, metadata: [
                "seq_len": "\(state.sequence.count)", "nodes": "\(state.graph.nodes.count)", "sources": "\(sources.count)",
            ])
        }
        let sourceEnd = MonotonicClock.nanoseconds()

        if state.collectStats {
            state.stats.stepTimings.rebuildGraphNanoseconds += graphEnd - graphStart
            state.stats.stepTimings.rebuildSourceNanoseconds += sourceEnd - graphEnd
        }

        state.valueChangeLog = []
        state.lastConvergencePass = [:]
        pendingReport = nil
        subPhase = .dispatch
        return .rebuilt(sequenceLength: state.sequence.count, structurallyChanged: diff.canReuseStructuralSources == false)
    }

    /// Rebuilds every exploitation source without updating stripped-graph state or clearing diagnostic history, preserving excursion policy.
    private mutating func rebuildExploitation(state: inout ReductionMachine) -> ReductionMachine.Transition {
        let exemptions = pendingReport.map { $0.acceptedLeafNodeIDs.union($0.convergenceRecords.keys) } ?? []
        let diff = state.rebuildAndUpdateGraph(valueGuardExemptNodeIDs: exemptions)
        sources = state.isDeadlineExceeded() ? [] : CandidateSourceBuilder.buildSources(from: state.graph)
        pendingReport = nil
        subPhase = .dispatch
        return .rebuilt(sequenceLength: state.sequence.count, structurallyChanged: diff.canReuseStructuralSources == false)
    }

    /// Publishes an interrupted main loop before machine finalization; exploitation instead applies its own report and stops for checkpoint settlement.
    mutating func finishAtDeadline(state: inout ReductionMachine) -> ReductionMachine.Transition {
        switch policy {
            case .main:
                state.dispatchLoop = self
                let transition = state.finishAtDeadline()
                self = state.dispatchLoop
                return transition
            case .exploitation:
                if let session = activeSession {
                    let report = session.report()
                    activeSession = nil
                    pendingReport = report
                    let action = state.applyPassPolicy(report)
                    if case .rebuildAndResume = action {
                        _ = rebuildExploitation(state: &state)
                    }
                    pendingReport = nil
                    sources = []
                    subPhase = .done
                    return .passCompleted(encoder: report.encoderName, accepted: report.anyAccepted)
                }
                if pendingReport != nil {
                    _ = rebuildExploitation(state: &state)
                }
                sources = []
                subPhase = .done
                return .dispatched(decision: .sourceExhausted)
        }
    }
}
