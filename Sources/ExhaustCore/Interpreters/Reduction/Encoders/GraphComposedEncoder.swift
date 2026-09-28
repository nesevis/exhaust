//
//  GraphComposedEncoder.swift
//  Exhaust
//

// MARK: - Graph Binary Search Encoder

/// Pure binary search over a single integer leaf in bit-pattern space, intended as the upstream slot of a ``GraphComposedEncoder``.
///
/// Operates on a one-leaf ``ValueMinimizationScope`` and emits a sequence of midpoint probes between the leaf's current bit pattern and its reduction target. On rejection, narrows the lower bound (`lo = lastProbe + 1`). On acceptance, narrows the upper bound (`hi = lastProbe`). Converges to the smallest accepted value, or to the original current value if every probe is rejected.
///
/// ## Why not ``GraphValueEncoder``?
///
/// ``GraphValueEncoder`` is designed for *standalone* integer minimization: after binary search converges short of the target, it falls into an inline linear scan (up to ``GraphValueEncoder/linearScanThreshold``) to look for non-monotone gaps, then a cross-zero phase for signed types. Both are appropriate when each probe is cheap. Inside a bound value composition, every upstream probe spawns one generator lift materialization plus a full downstream bound subtree search — so 10+ extra linear-scan upstream probes per dispatch is catastrophic. This encoder strips those phases down to plain binary search.
///
/// ## Lifecycle
///
/// 1. ``start(scope:)`` extracts the single leaf from the scope's ``ValueMinimizationScope``, reads its current and target bit patterns, and initializes a ``BinarySearchStepper``. Multi-leaf scopes are not supported and produce no probes.
/// 2. ``nextProbe(into:lastAccepted:)`` returns midpoint candidates until convergence. Each candidate writes the next bit pattern into the caller's inout buffer; the mutation is `.leafValues([LeafChange])` with `mayReshape: false` so the enclosing ``GraphComposedEncoder/wrap(downstreamMutation:candidate:upstreamProbe:)`` can flip the flag to `true` when wrapping the downstream probe.
///
/// - SeeAlso: ``GraphComposedEncoder``, ``BinarySearchStepper``
struct GraphBinarySearchEncoder: GraphEncoder {
    let name: EncoderName = .valueSearch

    private var leafNodeID: Int = -1
    private var sequenceIndex: Int = -1
    private var typeTag: TypeTag = .uint
    private var validRange: ClosedRange<UInt64>?
    private var isRangeExplicit: Bool = false
    private var stepper: BinarySearchStepper?
    private var baseSequence: ChoiceSequence = .init([])
    private var needsFirstProbe = true

    mutating func start(scope: EncoderInput) {
        leafNodeID = -1
        sequenceIndex = -1
        stepper = nil
        baseSequence = scope.baseSequence
        needsFirstProbe = true

        guard case let .minimize(.valueLeaves(integerScope)) = scope.transformation.operation,
              let entry = integerScope.leaves.first
        else { return }
        let graph = scope.graph
        guard entry.nodeID < graph.nodes.count,
              case let .chooseBits(metadata) = graph.nodes[entry.nodeID].kind,
              let range = graph.nodes[entry.nodeID].positionRange,
              range.lowerBound < scope.baseSequence.count,
              scope.baseSequence[range.lowerBound].value != nil
        else { return }

        let currentBitPattern = metadata.value.bitPattern64
        let targetBitPattern = metadata.value.reductionTarget(in: metadata.validRange)
        guard currentBitPattern != targetBitPattern else { return }

        leafNodeID = entry.nodeID
        sequenceIndex = range.lowerBound
        typeTag = metadata.typeTag
        validRange = metadata.validRange
        isRangeExplicit = metadata.isRangeExplicit
        if currentBitPattern > targetBitPattern {
            stepper = BinarySearchStepper(lo: targetBitPattern, hi: currentBitPattern, direction: .findSmallest)
        } else {
            stepper = BinarySearchStepper(lo: currentBitPattern, hi: targetBitPattern, direction: .findLargest)
        }
    }

    mutating func nextProbe(into candidate: inout ChoiceSequence, lastAccepted: Bool) -> EncoderProbe? {
        guard leafNodeID >= 0 else { return nil }

        let nextBitPattern: UInt64?
        if needsFirstProbe {
            needsFirstProbe = false
            nextBitPattern = stepper?.start()
        } else {
            nextBitPattern = stepper?.advance(lastAccepted: lastAccepted)
        }
        guard let bitPattern = nextBitPattern else { return nil }

        let newChoice = ChoiceValue(
            typeTag.makeConvertible(bitPattern64: bitPattern),
            tag: typeTag
        )
        candidate = baseSequence
        candidate[sequenceIndex] = .value(.init(
            choice: newChoice,
            validRange: validRange,
            isRangeExplicit: isRangeExplicit
        ))

        let change = LeafChange(
            leafNodeID: leafNodeID,
            newValue: newChoice,
            mayReshape: false
        )
        return .leafValues([change])
    }
}

// MARK: - Graph Bound Value Covering Encoder

/// Adapts ``BoundValueCoveringEncoder`` (a ``ComposableEncoder``) to the ``GraphEncoder`` protocol so it can be used as the downstream of a ``GraphComposedEncoder``.
///
/// The downstream slot of a bound value composition needs to *discover* failures in the lifted bound subtree, not minimize toward a known target. Per-coordinate value-search encoders (``GraphValueEncoder``) only move from the current value toward its semantic simplest, so they cannot find counterexamples that require moving *away* from the target — for example, the [1, 0] coupling that fails the property when the binary search starts from [0, 0].
///
/// ``BoundValueCoveringEncoder`` enumerates the entire bound value space (exhaustively for ≤ 128 combinations, pairwise covering for larger spaces) and is the right tool for that job.
///
/// The wrapper expects the scope's operation to be ``MinimizationScope/valueLeaves(_:)``: the leaf positions are read from the scope's leaves, the contiguous position range is computed from them, and the inner encoder is started on the scope's `baseSequence` over that range.
struct GraphBoundValueCoveringEncoder: GraphEncoder {
    let name: EncoderName = .boundValueSearch

    private var inner = BoundValueCoveringEncoder()
    private var leafEntries: [LeafEntry] = []
    private var hasInner = false

    mutating func start(scope: EncoderInput) {
        leafEntries = []
        hasInner = false

        guard case let .minimize(.valueLeaves(integerScope)) = scope.transformation.operation else {
            return
        }
        let graph = scope.graph
        let sequence = scope.baseSequence

        // Resolve leaf sequence positions and the spanning range.
        var lower = Int.max
        var upper = Int.min
        var validEntries: [LeafEntry] = []
        for entry in integerScope.leaves {
            guard entry.nodeID < graph.nodes.count,
                  let range = graph.nodes[entry.nodeID].positionRange,
                  range.lowerBound < sequence.count,
                  sequence[range.lowerBound].value != nil
            else { continue }
            lower = Swift.min(lower, range.lowerBound)
            upper = Swift.max(upper, range.upperBound)
            validEntries.append(entry)
        }
        guard lower <= upper, validEntries.isEmpty == false else { return }

        leafEntries = validEntries
        let positionRange = lower ... upper
        inner.start(
            sequence: sequence,
            tree: scope.tree,
            positionRange: positionRange
        )
        hasInner = true
    }

    mutating func nextProbe(into candidate: inout ChoiceSequence, lastAccepted: Bool) -> EncoderProbe? {
        guard hasInner else { return nil }
        guard let built = inner.nextProbe(lastAccepted: lastAccepted) else { return nil }
        // The composition's ``GraphComposedEncoder/wrap(downstreamProbe:upstreamProbe:)``
        // replaces this mutation with the upstream's reshape mutation, so we report an empty leafValues here as a placeholder — the candidate is what matters.
        candidate = built
        return .leafValues([])
    }
}

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
    private let probesPerStageTurn: Int
    private let maxBuildsPerStart: Int
    private let buildPool: CompositionBuildPool?

    private var parentScope: EncoderInput?
    private var activeStage: DownstreamStage?
    private var suspendedStages: [DownstreamStage] = []
    private var upstreamExhausted = false
    private var probesEmitted = 0

    /// Upstream probes that produced a valid lift during the current pass. Each one paid a generator materialization plus a downstream search, so this is the composition's expensive axis. Read by the pass report for diagnostics; deliberately not cleared by ``refreshState(graph:sequence:)`` so accepting passes report their true lift spend.
    private(set) var upstreamProbesUsed = 0

    /// Builder calls at this level in the current pass, including those that returned nil.
    private var ownDownstreamBuilds = 0
    /// Downstream builds of stages that ran dry or were dropped by ``refreshState(graph:sequence:)``, so their nested spend outlives the stage.
    private var retiredStageBuilds = 0

    /// Builder calls in the current pass by this composition and every composition nested below it, including builds that returned nil. Unlike ``upstreamProbesUsed``, a failed build counts: the bound value builder materializes before it can fail. Not cleared by ``refreshState(graph:sequence:)``.
    var downstreamBuilds: Int {
        var builds = ownDownstreamBuilds + retiredStageBuilds
        if let activeStage {
            builds += activeStage.encoder.downstreamBuilds
        }
        var stageIndex = 0
        while stageIndex < suspendedStages.count {
            builds += suspendedStages[stageIndex].encoder.downstreamBuilds
            stageIndex += 1
        }
        return builds
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
    ///   - probesPerStageTurn: Probes a downstream stage emits in one turn before the next stage takes over. `nil` runs each stage to exhaustion. Recursive compositions pass a small value to keep one controller tuple from consuming the root's total cap while retaining every downstream iterator for later turns.
    ///   - maxBuildsPerStart: Maximum builder calls at this level per ``start(scope:)`` call, counting builds that return nil. Unlike `upstreamBudget`, a failed build counts, since the builder may materialize before it fails.
    ///   - buildPool: Builder calls left to every composition sharing the pool, counting builds that return nil and builds whose downstream search emits nothing. Nested compositions draw from their root's pool, so work stays bounded however deep the nesting. `nil` leaves builds unbounded beyond `maxBuildsPerStart`.
    init(
        name: EncoderName,
        upstream: EncoderDispatch,
        upstreamScope: EncoderInput,
        upstreamBudget: Int = 15,
        totalProbeCap: Int = 0,
        probesPerStageTurn: Int? = nil,
        maxBuildsPerStart: Int = .max,
        buildPool: CompositionBuildPool? = nil,
        downstreamBuilder: @escaping DownstreamBuilder
    ) {
        self.name = name
        self.upstream = upstream
        buildDownstream = downstreamBuilder
        self.upstreamBudget = upstreamBudget
        self.totalProbeCap = totalProbeCap
        self.probesPerStageTurn = probesPerStageTurn ?? .max
        self.maxBuildsPerStart = maxBuildsPerStart
        self.buildPool = buildPool
        self.upstream.start(scope: upstreamScope)
    }

    /// Creates a composition whose downstream encoder type is fixed while its scope is lifted per upstream probe.
    init(
        name: EncoderName,
        upstream: EncoderDispatch,
        upstreamScope: EncoderInput,
        downstream: EncoderDispatch,
        upstreamBudget: Int = 15,
        totalProbeCap: Int = 0,
        probesPerStageTurn: Int? = nil,
        lift: @escaping (ChoiceSequence, EncoderProbe, EncoderInput) -> EncoderInput?
    ) {
        self.init(
            name: name,
            upstream: upstream,
            upstreamScope: upstreamScope,
            upstreamBudget: upstreamBudget,
            totalProbeCap: totalProbeCap,
            probesPerStageTurn: probesPerStageTurn,
            downstreamBuilder: { candidate, mutation, parent in
                guard let scope = lift(candidate, mutation, parent) else {
                    return nil
                }
                return (downstream, scope)
            }
        )
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
        ownDownstreamBuilds = 0
        retiredStageBuilds = 0
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
                retiredStageBuilds += stage.encoder.downstreamBuilds
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

    /// Advances upstream until the builder produces a downstream stage. `upstreamBudget` caps upstream probes that contributed to a valid downstream stage, so failed builds do not count against it. `maxBuildsPerStart` and the shared build pool count every builder call.
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
            guard ownDownstreamBuilds < maxBuildsPerStart, buildPool?.consume() ?? true else {
                upstreamExhausted = true
                return nil
            }
            ownDownstreamBuilds += 1
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
    /// ``upstreamProbesUsed`` and ``downstreamBuilds`` are intentionally left intact: with `parentScope` nil the budget loop is unreachable, so the counters are dead for control flow, and clearing them would erase the lift spend from the pass report of exactly the accepting passes.
    mutating func refreshState(graph _: ChoiceGraph, sequence _: ChoiceSequence) {
        retiredStageBuilds = downstreamBuilds - ownDownstreamBuilds
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

// MARK: - Build Pool

/// Builder calls left to one dispatch of a composition and every composition nested below it.
///
/// A class so that nested compositions, which are copied into ``EncoderDispatch`` values, all draw from the root's count. Nesting otherwise multiplies each level's builds, so a per-level limit alone does not bound the total.
final class CompositionBuildPool {
    private(set) var remaining: Int

    init(capacity: Int) {
        remaining = capacity
    }

    /// Takes one build from the pool, returning false when none remain.
    func consume() -> Bool {
        guard remaining > 0 else {
            return false
        }
        remaining -= 1
        return true
    }
}
