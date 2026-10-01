//
//  GraphComposedEncoder.swift
//  Exhaust
//

// MARK: - Graph Composed Encoder

/// Lifts proposals and schedules operation-specific searches built from each freshly lifted result.
///
/// Proposal generation never receives acceptance feedback. The factory validates each lift before constructing its downstream encoder and scope; a nested composition receives the lifted graph and its operation's chain context. The engine owns lift attempts, constructed-stage counts, probe caps, and active and suspended searches.
///
/// ## Iteration Semantics
///
/// - Outer loop: pull proposals from ``LiftProposalSource``.
/// - For each proposal, attempt a lift and call the downstream factory. A constructed encoder and scope form one downstream stage.
/// - Inner loop: pull the active stage's probes; emit each one via ``wrap(upstreamProbe:)``.
/// - When the active stage has used its turn, suspend it and start the next upstream probe's stage. Once upstream is exhausted or over budget, resume suspended stages in round-robin order, one turn each. Without a turn limit, each stage runs to exhaustion before the next upstream probe is pulled.
///
/// Every stage receives rejection feedback. The operation's acceptance policy either refreshes to idle or applies the upstream mutation and ends the session when it requires a rebuild.
///
/// ## Mutation Reporting
///
/// The downstream encoder's mutation references node IDs in the *lifted* graph, which mean nothing to the live graph after acceptance. The composition discards the downstream mutation and emits the upstream's mutation with ``LeafChange/mayReshape`` set to `true`, triggering a full graph rebuild on acceptance. The downstream's actual values are baked into the candidate sequence — the materializer reads them when the decoder reconstructs the freshTree.
///
/// ## Convergence
///
/// Proposals receive no acceptance feedback and expose no convergence records. Downstream convergence is local to the lifted graph and cannot be transferred to the live graph.
///
struct GraphComposedEncoder: StatefulGraphEncoder {
    let name: EncoderName

    typealias Lift = (_ prefix: ChoiceSequence, _ fallbackTree: ChoiceTree) -> ChoiceTree?
    typealias ProposalSourceFactory = (_ scope: EncoderInput) -> LiftProposalSource?
    typealias PreparedSearch = (source: LiftProposalSource, downstreamFactory: DownstreamFactory)
    typealias ProposalFactory = (_ scope: EncoderInput) -> PreparedSearch?
    typealias DownstreamFactory = (
        _ proposal: LiftProposal,
        _ lifted: LiftResult,
        _ parent: EncoderInput
    ) -> DownstreamBuild

    private struct DownstreamStage {
        var encoder: EncoderDispatch
        let upstreamProbe: EncoderProbe
        var probesRemainingInTurn: Int
    }

    private var proposals: LiftProposalSource?
    private let makeProposals: ProposalFactory
    private let liftProposal: Lift
    private var buildDownstream: DownstreamFactory?
    private let policy: CompositionPolicy
    private let recordLiftAttempt: (() -> Void)?
    private let recordBuild: ((DownstreamBuild) -> Void)?

    private var parentScope: EncoderInput?
    private var activeStage: DownstreamStage?
    private var suspendedStages: [DownstreamStage] = []
    private var upstreamExhausted = false

    private(set) var ledger = LiftLedger()

    var upstreamProbesUsed: Int {
        ledger.constructedStages
    }

    var requiresExactDecoder: Bool {
        policy.requiresExactDecoder
    }

    var acceptanceHandling: AcceptanceHandling {
        policy.acceptanceHandling
    }

    /// Probes a stage emits before the next stage takes over. Unlimited outside a nested chain, so each stage runs to exhaustion.
    private var probesPerStageTurn: Int {
        policy.chainLimits?.probesPerStageTurn ?? .max
    }

    /// Initializes proposals from each dispatched scope. Lift-result construction stays in the engine; operation-specific factories receive the complete lifted tree and sequence. Optional accounting callbacks preserve bound value's run-wide records without giving other operations its construction context.
    init(
        name: EncoderName,
        makeProposals: @escaping ProposalFactory,
        policy: CompositionPolicy = CompositionPolicy(),
        lift: @escaping Lift,
        recordLiftAttempt: (() -> Void)? = nil,
        recordBuild: ((DownstreamBuild) -> Void)? = nil
    ) {
        self.name = name
        self.makeProposals = makeProposals
        self.policy = policy
        liftProposal = lift
        self.recordLiftAttempt = recordLiftAttempt
        self.recordBuild = recordBuild
    }

    /// Uses a fixed downstream factory when proposal initialization does not need to parse an operation-specific scope.
    init(
        name: EncoderName,
        makeProposals: @escaping ProposalSourceFactory,
        policy: CompositionPolicy = CompositionPolicy(),
        lift: @escaping Lift,
        recordLiftAttempt: (() -> Void)? = nil,
        recordBuild: ((DownstreamBuild) -> Void)? = nil,
        downstreamFactory: @escaping DownstreamFactory
    ) {
        self.init(
            name: name,
            makeProposals: { scope in
                makeProposals(scope).map { (source: $0, downstreamFactory: downstreamFactory) }
            },
            policy: policy,
            lift: lift,
            recordLiftAttempt: recordLiftAttempt,
            recordBuild: recordBuild
        )
    }

    mutating func start(scope: EncoderInput) {
        parentScope = scope
        activeStage = nil
        suspendedStages = []
        upstreamExhausted = false
        ledger = LiftLedger()
        let prepared = makeProposals(scope)
        proposals = prepared?.source
        buildDownstream = prepared?.downstreamFactory
    }

    mutating func nextProbe(into candidate: inout ChoiceSequence, lastAccepted _: Bool) -> EncoderProbe? {
        if policy.totalProbeCap > 0, ledger.emittedProbes >= policy.totalProbeCap {
            return nil
        }
        guard let parent = parentScope else {
            return nil
        }

        while true {
            if activeStage == nil {
                activeStage = nextStage(candidate: candidate, parent: parent)
            }
            guard var stage = activeStage else {
                return nil
            }
            activeStage = nil
            guard stage.encoder.nextProbe(
                into: &candidate,
                lastAccepted: false
            ) != nil else {
                continue
            }

            stage.probesRemainingInTurn -= 1
            if stage.probesRemainingInTurn == 0 {
                suspendedStages.append(stage)
            } else {
                activeStage = stage
            }
            ledger.emittedProbes += 1
            return wrap(upstreamProbe: stage.upstreamProbe)
        }
    }

    /// Starts the next upstream candidate's stage, or resumes the oldest suspended stage once upstream is exhausted or over budget.
    private mutating func nextStage(
        candidate: ChoiceSequence,
        parent: EncoderInput
    ) -> DownstreamStage? {
        if let pulled = pullUpstreamStage(candidate: candidate, parent: parent) {
            return pulled
        }
        guard suspendedStages.isEmpty == false else {
            return nil
        }
        var resumed = suspendedStages.removeFirst()
        resumed.probesRemainingInTurn = probesPerStageTurn
        return resumed
    }

    /// Advances proposals until the factory constructs a stage. The stage budget includes empty searches but not failed builds; optional chain limits count every attempted lift.
    private mutating func pullUpstreamStage(
        candidate: ChoiceSequence,
        parent: EncoderInput
    ) -> DownstreamStage? {
        guard let buildDownstream else {
            return nil
        }
        var upstreamCandidate = candidate
        while upstreamExhausted == false, ledger.constructedStages < (policy.stageBudget ?? .max) {
            guard let proposal = proposals?.next(into: &upstreamCandidate) else {
                upstreamExhausted = true
                return nil
            }
            guard policy.chainLimits?.consumeBuild(afterBuildsThisStart: ledger.attempts) ?? true else {
                upstreamExhausted = true
                return nil
            }
            ledger.attempts += 1
            recordLiftAttempt?()
            let built: DownstreamBuild = switch liftProposal(proposal.prefix, parent.tree) {
                case let tree?:
                    buildDownstream(proposal, LiftResult(tree: tree, sequence: ChoiceSequence(tree)), parent)
                case nil:
                    .failed(.materializationFailed)
            }
            recordBuild?(built)
            guard case let .stage(encoder, scope) = built else {
                continue
            }
            ledger.constructedStages += 1
            var downstream = encoder
            downstream.start(scope: scope)
            return DownstreamStage(
                encoder: downstream,
                upstreamProbe: proposal.mutation,
                probesRemainingInTurn: probesPerStageTurn
            )
        }
        return nil
    }

    /// Resets the composition to idle when a mid-pass structural acceptance has updated the live sequence.
    ///
    /// The composition caches the pre-dispatch scope, the in-flight upstream probe, and the downstream stages. After any accepted probe triggers a reshape or full rebuild, all three are stale — the upstream binary search was calibrated to the old sequence, the lifted downstream scopes were built from the old tree, and continuing would emit probes that may not shortlex-precede the new live sequence. Resetting to idle aborts the current pass; the scheduler re-dispatches a fresh composition next cycle.
    ///
    /// The ledger remains intact for pass reporting. With `parentScope` nil, its counters are unreachable from the budget loop.
    mutating func refreshState(graph _: ChoiceGraph, sequence _: ChoiceSequence) {
        parentScope = nil
        activeStage = nil
        suspendedStages = []
    }

    /// Replaces a downstream probe's mutation with the upstream's mutation, lifted to set ``LeafChange/mayReshape`` to `true`.
    ///
    /// The candidate sequence is already in the caller's inout buffer; the mutation is what the live graph applies on accept (one upstream leaf change with ``LeafChange/mayReshape`` set to `true`, triggering a full graph rebuild).
    private func wrap(upstreamProbe: EncoderProbe) -> EncoderProbe {
        guard case let .leafValues(upstreamChanges) = upstreamProbe else {
            return upstreamProbe
        }
        let reshapeChanges = upstreamChanges.map { change in
            LeafChange(
                leafNodeID: change.leafNodeID,
                newValue: change.newValue,
                mayReshape: true
            )
        }
        return .leafValues(reshapeChanges)
    }
}
