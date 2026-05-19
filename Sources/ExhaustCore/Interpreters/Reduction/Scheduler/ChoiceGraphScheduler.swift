//
//  ChoiceGraphScheduler.swift
//  Exhaust
//

// MARK: - Choice Graph Scheduler

/// Pure decision functions and entry points for the graph-based reduction pipeline.
///
/// The stateful reduction logic lives in ``ReductionMachine``. This enum provides:
/// - Entry points (``run``, ``runCollectingStats``) that construct and drive the machine.
/// - Pure decision functions (``evaluateDispatch``, ``evaluateAcceptance``, ``evaluatePostCycle``) that compute scheduling decisions from immutable inputs.
/// - Encoder selection and instrumentation helpers shared by the machine and its sub-systems.
enum ChoiceGraphScheduler {

    // MARK: - Entry Points

    /// Reduces a failing counterexample by constructing and driving a ``ReductionMachine`` to completion.
    static func run<Output>(
        gen: Generator<Output>,
        initialTree: ChoiceTree,
        initialOutput: Output,
        config: Interpreters.ReducerConfiguration,
        property: @escaping (Output) -> Bool
    ) throws -> (ChoiceSequence, Output)? {
        var machine = ReductionMachine(
            gen: gen,
            initialTree: initialTree,
            initialOutput: initialOutput,
            config: config,
            collectStats: false,
            property: property
        )
        while try machine.next() != nil {}
        return machine.typedResult().reduced
    }

    /// Reduces a failing counterexample with per-step wall-time measurement, returning both the reduced result and accumulated ``ReductionStats`` including ``ReductionStats/StepTimings``.
    static func runCollectingStats<Output>(
        gen: Generator<Output>,
        initialTree: ChoiceTree,
        initialOutput: Output,
        config: Interpreters.ReducerConfiguration,
        property: @escaping (Output) -> Bool
    ) throws -> (reduced: (ChoiceSequence, Output)?, stats: ReductionStats) {
        var machine = ReductionMachine(
            gen: gen,
            initialTree: initialTree,
            initialOutput: initialOutput,
            config: config,
            collectStats: true,
            property: property
        )
        var lastStep = monotonicNanoseconds()
        while let transition = try machine.next() {
            let now = monotonicNanoseconds()
            machine.stats.stepTimings.record(transition, elapsed: now - lastStep)
            lastStep = now
        }
        return machine.typedResult()
    }

    // MARK: - Source Selection

    /// Returns the index of the source with the highest peekPriority, or nil if all are exhausted.
    static func highestPrioritySourceIndex(
        _ sources: [AnyCandidateSource]
    ) -> Int? {
        var bestIndex: Int?
        var bestPriority: DispatchPriority?
        for (index, source) in sources.enumerated() {
            guard let priority = source.peekPriority else { continue }
            if let currentBest = bestPriority {
                if priority > currentBest {
                    bestIndex = index
                    bestPriority = priority
                }
            } else {
                bestIndex = index
                bestPriority = priority
            }
        }
        return bestIndex
    }

    // MARK: - Instrumentation

    @inline(__always)
    static func logReducer(
        _ event: String,
        isInstrumented: Bool,
        metadata: @autoclosure () -> [String: String]
    ) {
        guard isInstrumented else { return }
        ExhaustLog.debug(category: .reducer, event: event, metadata: metadata())
    }

    // MARK: - Post-Acceptance Evaluation

    /// What the scheduler should do after a probe loop completes.
    enum PostAcceptanceAction: Equatable {
        case continueDispatching
        case rebuildAndResume(treeIsStripped: Bool)
    }

    /// Determines whether the scheduler should rebuild the graph or continue dispatching after an encoder pass completes. Pure function of the probe outcome and operation type.
    static func evaluateAcceptance(
        outcome: ProbeLoopOutcome,
        operation: GraphOperation
    ) -> PostAcceptanceAction {
        guard outcome.accepted else {
            return .continueDispatching
        }
        let isBoundValue = switch operation {
        case .minimize(.boundValue):
            true
        default:
            false
        }
        if outcome.requiresRebuild || isBoundValue {
            return .rebuildAndResume(treeIsStripped: outcome.treeIsStripped)
        }
        return .continueDispatching
    }

    // MARK: - Dispatch Evaluation

    /// Decision returned by ``evaluateDispatch`` indicating what the dispatch step should do with a candidate transformation.
    enum DispatchDecision: Equatable {
        case skip
        case classifyBind(bindNodeID: Int, fingerprint: UInt64)
        case rematerialize
        case readyToDispatch(boundValueFingerprint: UInt64?)
    }

    /// Determines whether a candidate transformation should be dispatched, skipped, or requires a classification effect before proceeding. Pure function of the transformation, graph state, caches, and flags.
    static func evaluateDispatch(
        transformation: GraphTransformation,
        graph: ChoiceGraph,
        sequence: ChoiceSequence,
        gate: BoundValueGate,
        scopeCache: CandidateRejectionCache,
        graphIsStripped: Bool,
        anyAccepted: Bool
    ) -> DispatchDecision {
        guard transformation.operation.isValid(in: graph) else {
            return .skip
        }

        if scopeCache.isRejected(
            operation: transformation.operation,
            sequence: sequence,
            graph: graph
        ) {
            return .skip
        }

        if case let .minimize(.boundValue(bindScope)) = transformation.operation {
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
                if let cached = graph.bindClassifications[fingerprint] {
                    if cached.topology != .identical || cached.liftability != .both {
                        return .skip
                    }
                } else {
                    return .classifyBind(bindNodeID: bindScope.bindNodeID, fingerprint: fingerprint)
                }
            case .dispatch:
                break
            }

            return .readyToDispatch(boundValueFingerprint: fingerprint)
        }

        if graphIsStripped, transformation.operation.isPathChanging {
            return .rematerialize
        }

        return .readyToDispatch(boundValueFingerprint: nil)
    }

    // MARK: - Encoder Selection

    /// Selects the appropriate encoder for a graph operation type. Bound value minimization scopes are not handled here because they require the typed generator at construction time; the dispatch step builds them via ``makeBoundValueComposition(bindScope:scope:graph:gen:upstreamBudget:)`` instead.
    static func selectEncoder(for operation: GraphOperation) -> any GraphEncoder {
        switch operation {
        case .remove, .replace, .migrate:
            GraphStructuralEncoder()
        case .permute:
            GraphSwapEncoder()
        case .minimize:
            GraphValueEncoder()
        case .exchange(.redistribution):
            GraphRedistributionEncoder()
        case .exchange(.tandem):
            GraphLockstepEncoder()
        case .reorder:
            GraphReorderEncoder()
        }
    }

    // MARK: - Post-Cycle Evaluation

    /// Snapshot of what happened during a single reduction cycle, consumed by ``evaluatePostCycle`` to determine the next actions.
    struct CycleOutcome: Sendable {
        let anyAccepted: Bool
        let hadReplacementShortlexRejection: Bool
        let allConverged: Bool
        let improved: Bool
        let structurallyImproved: Bool
    }

    /// Actions the machine should take after a reduction cycle completes. Termination is not an action — it depends on post-effect state (a successful relax round prevents termination, and convergence confirmation can clear stale floors that change the ``allValuesConverged`` result).
    enum PostCycleAction: Equatable, Sendable {
        case confirmConvergence
        case relaxRound
        case releaseDeferral
    }

    /// Result of evaluating a cycle's outcome, containing the ordered list of actions to attempt and updated loop control values.
    struct PostCycleEvaluation: Equatable, Sendable {
        let actions: [PostCycleAction]
        let newStallBudget: Int
        let newDeferBindInner: Bool
    }

    /// Determines what should happen after a reduction cycle completes. Pure function of the cycle outcome, current stall budget, deferral state, and max stalls.
    static func evaluatePostCycle(
        outcome: CycleOutcome,
        stallBudget: Int,
        maxStalls: Int,
        deferBindInner: Bool
    ) -> PostCycleEvaluation {
        var actions: [PostCycleAction] = []

        if outcome.anyAccepted == false, outcome.allConverged {
            actions.append(.confirmConvergence)
        }

        if outcome.anyAccepted == false, outcome.hadReplacementShortlexRejection {
            actions.append(.relaxRound)
        }

        let newStallBudget = outcome.improved ? maxStalls : stallBudget - 1

        var newDeferBindInner = deferBindInner
        if deferBindInner, outcome.structurallyImproved == false {
            newDeferBindInner = false
            actions.append(.releaseDeferral)
        }

        return PostCycleEvaluation(
            actions: actions,
            newStallBudget: newStallBudget,
            newDeferBindInner: newDeferBindInner
        )
    }
}
