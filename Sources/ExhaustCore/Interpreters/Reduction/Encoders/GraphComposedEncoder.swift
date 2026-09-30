//
//  GraphComposedEncoder.swift
//  Exhaust
//

// MARK: - Graph Composed Encoder

/// Composes two ``GraphEncoder``s through a builder that translates each upstream probe into a downstream encoder and ``EncoderInput``.
///
/// The upstream and downstream encoders operate on separate scopes. The upstream scope is fixed at construction time; the downstream builder produces a fresh encoder and scope for each upstream probe. Returning an encoder as well as its scope lets one composition place another composition downstream. When the scheduler calls ``start(scope:)``, the composition stores that scope as the parent context for the builder but does not forward it to the upstream encoder.
///
/// ## Iteration Semantics
///
/// - Outer loop: pull upstream probes via ``GraphEncoder/nextProbe(into:lastAccepted:)``.
/// - For each upstream probe, call the downstream builder to create an encoder and scope. Together they form one downstream stage.
/// - Inner loop: pull the active stage's probes; emit each one via ``wrap(downstreamMutation:candidate:upstreamProbe:)``.
/// - When the active stage has used its turn, suspend it and start the next upstream probe's stage. Once upstream is exhausted or over budget, resume suspended stages in round-robin order, one turn each. Without a turn limit, each stage runs to exhaustion before the next upstream probe is pulled.
///
/// Every stage receives rejection feedback: an accepted probe triggers ``refreshState(graph:sequence:)``, which aborts the pass.
///
/// ## Mutation Reporting
///
/// The downstream encoder's mutation references node IDs in the *lifted* graph, which mean nothing to the live graph after acceptance. The composition discards the downstream mutation and emits the upstream's mutation with ``LeafChange/mayReshape`` set to `true`, triggering a full graph rebuild on acceptance. The downstream's actual values are baked into the candidate sequence — the materializer reads them when the decoder reconstructs the freshTree.
///
/// ## Convergence
///
/// Only the upstream encoder's convergence records are exposed to the scheduler. The downstream encoder cold-starts on each upstream probe via ``GraphEncoder/start(scope:)``, so any convergence it accumulates is downstream-local and not transferable to the live graph.
///
struct GraphComposedEncoder: StatefulGraphEncoder {
    let name: EncoderName

    typealias DownstreamBuilder = (
        ChoiceSequence,
        EncoderProbe,
        EncoderInput
    ) -> (encoder: EncoderDispatch, scope: EncoderInput)?

    private struct DownstreamStage {
        var encoder: EncoderDispatch
        let upstreamProbe: EncoderProbe
        var probesRemainingInTurn: Int
    }

    private var upstream: EncoderDispatch
    private let buildDownstream: DownstreamBuilder
    private let upstreamBudget: Int
    private let totalProbeCap: Int
    private let chainLimits: NestedChainLimits?

    private var parentScope: EncoderInput?
    private var activeStage: DownstreamStage?
    private var suspendedStages: [DownstreamStage] = []
    private var upstreamExhausted = false
    private var probesEmitted = 0

    /// Upstream probes that produced a valid lift during the current pass. Each one paid a generator materialization plus a downstream search, so this is the composition's expensive axis. Read by the pass report for diagnostics; deliberately not cleared by ``refreshState(graph:sequence:)`` so accepting passes report their true lift spend.
    private(set) var upstreamProbesUsed = 0

    /// Builder calls at this level in the current pass, including those that returned nil. Enforces ``NestedChainLimits/maxBuildsPerStart``.
    private var downstreamBuilds = 0

    /// Probes a stage emits before the next stage takes over. Unlimited outside a nested chain, so each stage runs to exhaustion.
    private var probesPerStageTurn: Int {
        chainLimits?.probesPerStageTurn ?? .max
    }

    /// Creates a composition and starts the upstream encoder on `upstreamScope`.
    ///
    /// - Parameters:
    ///   - name: Encoder name reported to the scheduler for stats and logging.
    ///   - upstream: Encoder driving the outer iteration. Started immediately on `upstreamScope`.
    ///   - upstreamScope: The scope the upstream encoder searches over. Fixed for the lifetime of this composition.
    ///   - downstreamBuilder: Builds the encoder and scope that search one lifted upstream candidate. Returning another ``GraphComposedEncoder`` recursively searches a nested dependency.
    ///   - upstreamBudget: Maximum number of upstream probes pulled per ``start(scope:)`` call. Each upstream probe triggers one downstream build plus a downstream search, so this caps the most expensive part of the composition. Pass a larger value when the upstream domain is small relative to the budget.
    ///   - totalProbeCap: Maximum probes the composition emits per ``start(scope:)`` call, across all lifts. Zero means uncapped. Intended for a bind fingerprint's first dispatch of the run, where a fruitless multi-leaf covering enumeration would otherwise run to exhaustion before the gate can blacklist the bind.
    ///   - chainLimits: Stage turns and build limits for a composition in a chain of nested compositions. `nil` runs each stage to exhaustion and leaves builds bounded only by `upstreamBudget`.
    init(
        name: EncoderName,
        upstream: EncoderDispatch,
        upstreamScope: EncoderInput,
        upstreamBudget: Int = 15,
        totalProbeCap: Int = 0,
        chainLimits: NestedChainLimits? = nil,
        downstreamBuilder: @escaping DownstreamBuilder
    ) {
        self.name = name
        self.upstream = upstream
        buildDownstream = downstreamBuilder
        self.upstreamBudget = upstreamBudget
        self.totalProbeCap = totalProbeCap
        self.chainLimits = chainLimits
        self.upstream.start(scope: upstreamScope)
    }

    /// Convergence records from the upstream encoder.
    ///
    /// The downstream encoder's records are scoped to the lifted graph and meaningless on the live graph after acceptance — they are deliberately not exposed.
    var convergenceRecords: [Int: ConvergedOrigin] {
        upstream.convergenceRecords
    }

    mutating func start(scope: EncoderInput) {
        parentScope = scope
        activeStage = nil
        suspendedStages = []
        upstreamExhausted = false
        upstreamProbesUsed = 0
        downstreamBuilds = 0
        probesEmitted = 0
    }

    mutating func nextProbe(into candidate: inout ChoiceSequence, lastAccepted _: Bool) -> EncoderProbe? {
        if totalProbeCap > 0, probesEmitted >= totalProbeCap {
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
            guard let downstreamMutation = stage.encoder.nextProbe(
                into: &candidate,
                lastAccepted: false
            ) else {
                continue
            }

            stage.probesRemainingInTurn -= 1
            if stage.probesRemainingInTurn == 0 {
                suspendedStages.append(stage)
            } else {
                activeStage = stage
            }
            probesEmitted += 1
            return wrap(
                downstreamMutation: downstreamMutation,
                candidate: candidate,
                upstreamProbe: stage.upstreamProbe
            )
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

    /// Advances upstream until the builder produces a downstream stage. `upstreamBudget` caps upstream probes that contributed to a valid downstream stage, so failed builds do not count against it. The chain limits count every builder call.
    private mutating func pullUpstreamStage(
        candidate: ChoiceSequence,
        parent: EncoderInput
    ) -> DownstreamStage? {
        var upstreamCandidate = candidate
        while upstreamExhausted == false, upstreamProbesUsed < upstreamBudget {
            guard let upstreamMutation = upstream.nextProbe(
                into: &upstreamCandidate,
                lastAccepted: false
            ) else {
                upstreamExhausted = true
                return nil
            }
            guard chainLimits?.consumeBuild(afterBuildsThisStart: downstreamBuilds) ?? true else {
                upstreamExhausted = true
                return nil
            }
            downstreamBuilds += 1
            guard var built = buildDownstream(upstreamCandidate, upstreamMutation, parent) else {
                continue
            }
            upstreamProbesUsed += 1
            built.encoder.start(scope: built.scope)
            return DownstreamStage(
                encoder: built.encoder,
                upstreamProbe: upstreamMutation,
                probesRemainingInTurn: probesPerStageTurn
            )
        }
        return nil
    }

    /// Resets the composition to idle when a mid-pass structural acceptance has updated the live sequence.
    ///
    /// The composition caches the pre-dispatch scope, the in-flight upstream probe, and the downstream stages. After any accepted probe triggers a reshape or full rebuild, all three are stale — the upstream binary search was calibrated to the old sequence, the lifted downstream scopes were built from the old tree, and continuing would emit probes that may not shortlex-precede the new live sequence. Resetting to idle aborts the current pass; the scheduler re-dispatches a fresh composition next cycle.
    ///
    /// ``upstreamProbesUsed`` is intentionally left intact: with `parentScope` nil the budget loop is unreachable, so the counter is dead for control flow, and clearing it would erase the lift spend from the pass report of exactly the accepting passes.
    mutating func refreshState(graph _: ChoiceGraph, sequence _: ChoiceSequence) {
        parentScope = nil
        activeStage = nil
        suspendedStages = []
    }

    /// Replaces a downstream probe's mutation with the upstream's mutation, lifted to set ``LeafChange/mayReshape`` to `true`.
    ///
    /// The candidate sequence is already in the caller's inout buffer; the mutation is what the live graph applies on accept (one upstream leaf change with ``LeafChange/mayReshape`` set to `true`, triggering a full graph rebuild).
    private func wrap(
        downstreamMutation _: EncoderProbe,
        candidate _: ChoiceSequence,
        upstreamProbe: EncoderProbe
    ) -> EncoderProbe {
        guard case let .leafValues(upstreamChanges) = upstreamProbe else {
            // Non-leafValues upstream mutations are not the intended use of this primitive.
            // Pass the upstream mutation through defensively rather than fabricating one.
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
