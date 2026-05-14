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
        while try machine.next() != nil {}
        return machine.typedResult()
    }

    // MARK: - Source Selection

    /// Returns the index of the source with the highest peekPriority, or nil if all are exhausted.
    static func highestPrioritySourceIndex(
        _ sources: [any CandidateSource]
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

    enum DispatchDecision: Equatable {
        case skip
        case classifyBind(bindNodeID: Int, fingerprint: UInt64)
        case rematerialize
        case readyToDispatch(boundValueFingerprint: UInt64?)
    }

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

    struct CycleOutcome: Sendable {
        let anyAccepted: Bool
        let hadReplacementShortlexRejection: Bool
        let allConverged: Bool
        let improved: Bool
        let structurallyImproved: Bool
    }

    enum PostCycleAction: Equatable, Sendable {
        case confirmConvergence
        case relaxRound
        case releaseDeferral
    }

    struct PostCycleEvaluation: Equatable, Sendable {
        let actions: [PostCycleAction]
        let newStallBudget: Int
        let newDeferBindInner: Bool
    }

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
