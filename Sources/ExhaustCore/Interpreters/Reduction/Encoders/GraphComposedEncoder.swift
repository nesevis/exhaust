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
/// ``GraphValueEncoder`` is designed for *standalone* integer minimization: after binary search converges short of the target, it falls into an inline linear scan (up to ``GraphValueEncoder/linearScanThreshold``) to look for non-monotone gaps, then a cross-zero phase for signed types. Both are appropriate when each probe is cheap. Inside a bound value composition, every upstream probe spawns one generator lift materialisation plus a full downstream fibre search — so 10+ extra linear-scan upstream probes per dispatch is catastrophic. This encoder strips those phases down to plain binary search.
///
/// ## Lifecycle
///
/// 1. ``start(scope:)`` extracts the single leaf from the scope's ``ValueMinimizationScope``, reads its current and target bit patterns, and initialises a ``BinarySearchStepper``. Multi-leaf scopes are not supported and produce no probes.
/// 2. ``nextProbe(lastAccepted:)`` returns midpoint candidates until convergence. Each candidate writes the next bit pattern into the leaf's sequence position; the mutation is `.leafValues([LeafChange])` with `mayReshape: false` so the enclosing ``GraphComposedEncoder/wrap(downstreamProbe:upstreamProbe:)`` can flip the flag to `true` when wrapping the downstream probe.
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

    mutating func start(scope: TransformationScope) {
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

        let currentBP = metadata.value.bitPattern64
        let targetBP = metadata.value.reductionTarget(in: metadata.validRange)
        guard currentBP > targetBP else { return }

        leafNodeID = entry.nodeID
        sequenceIndex = range.lowerBound
        typeTag = metadata.typeTag
        validRange = metadata.validRange
        isRangeExplicit = metadata.isRangeExplicit
        stepper = BinarySearchStepper(lo: targetBP, hi: currentBP)
    }

    mutating func nextProbe(lastAccepted: Bool) -> EncoderProbe? {
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
        var candidate = baseSequence
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
        return EncoderProbe(candidate: candidate, mutation: .leafValues([change]))
    }
}

// MARK: - Graph Fibre Covering Encoder

/// Adapts ``FibreCoveringEncoder`` (a ``ComposableEncoder``) to the ``GraphEncoder`` protocol so it can be used as the downstream of a ``GraphComposedEncoder``.
///
/// The downstream slot of a bound value composition needs to *discover* failures in the lifted fibre, not minimize toward a known target. Per-coordinate value-search encoders (``GraphValueEncoder``) only move from the current value toward its semantic simplest, so they cannot find counterexamples that require moving *away* from the target — for example, the [1, 0] coupling that fails the property when the binary search starts from [0, 0].
///
/// ``FibreCoveringEncoder`` enumerates the entire fibre value space (exhaustively for ≤ 128 combinations, pairwise covering for larger spaces) and is the right tool for that job.
///
/// The wrapper expects the scope's operation to be ``MinimizationScope/valueLeaves(_:)``: the leaf positions are read from the scope's leaves, the contiguous position range is computed from them, and the inner encoder is started on the scope's `baseSequence` over that range.
struct GraphFibreCoveringEncoder: GraphEncoder {
    let name: EncoderName = .boundValueSearch

    private var inner = FibreCoveringEncoder()
    private var leafEntries: [LeafEntry] = []
    private var hasInner = false

    mutating func start(scope: TransformationScope) {
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

    mutating func nextProbe(lastAccepted: Bool) -> EncoderProbe? {
        guard hasInner else { return nil }
        guard let candidate = inner.nextProbe(lastAccepted: lastAccepted) else { return nil }
        // The composition's ``GraphComposedEncoder/wrap(downstreamProbe:upstreamProbe:)``
        // replaces this mutation with the upstream's reshape mutation, so we report an
        // empty leafValues here as a placeholder — the candidate is what matters.
        return EncoderProbe(candidate: candidate, mutation: .leafValues([]))
    }
}

// MARK: - Graph Composed Encoder

/// Composes two ``GraphEncoder``s through a lift closure that translates an upstream probe into a downstream ``TransformationScope``.
///
/// Categorically a bound value composition of two ``GraphEncoder`` arrows. The upstream encoder operates on the original scope and produces probes; the lift closure runs the upstream candidate through the generator (or any other transform) and constructs a fresh scope for the downstream encoder; the downstream encoder operates on that scope and produces probes which the composition wraps and re-emits with the upstream's mutation attached.
///
/// ## Iteration Semantics
///
/// - Outer loop: pull upstream probes via ``GraphEncoder/nextProbe(lastAccepted:)``.
/// - For each upstream probe, call ``lift`` to build a downstream scope.
/// - Inner loop: pull downstream probes; emit each one via ``wrap(downstreamProbe:upstreamProbe:)``.
/// - On downstream exhaustion, advance to the next upstream probe.
///
/// ## Mutation Reporting
///
/// The downstream encoder's mutation references node IDs in the *lifted* graph, which mean nothing to the live graph after acceptance. The composition discards the downstream mutation and emits the upstream's mutation with ``LeafChange/mayReshape`` set to `true`, which routes ``ChoiceGraph/applyBindReshape(forLeaf:freshTree:into:)`` to splice the rebuilt subtree from the decoder's freshTree on accept. The downstream's actual values are baked into the candidate sequence — the materializer reads them when the decoder reconstructs the freshTree.
///
/// ## Decoder Hint
///
/// Always sets ``requiresExactDecoder`` to `true` because lifted candidates carry a new bound subtree that conflicts with the parent tree's fallback content. The scheduler reads this flag and routes probes through ``SequenceDecoder/exact(materializePicks:)``.
///
/// ## Convergence
///
/// Only the upstream encoder's convergence records are exposed to the scheduler. The downstream encoder cold-starts on each upstream probe via ``GraphEncoder/start(scope:)``, so any convergence it accumulates is fibre-local and not transferable to the live graph.
///

struct GraphComposedEncoder: GraphEncoder {
    let name: EncoderName
    let requiresExactDecoder: Bool = true

    private var upstream: any GraphEncoder
    private var downstream: any GraphEncoder
    private let lift: (EncoderProbe, TransformationScope) -> TransformationScope?
    private let upstreamBudget: Int

    private var originalScope: TransformationScope?
    private var currentUpstreamProbe: EncoderProbe?
    private var downstreamActive = false
    private var upstreamProbesUsed = 0

    /// Creates a composition.
    ///
    /// - Parameters:
    ///   - name: Encoder name reported to the scheduler for stats and logging.
    ///   - upstream: Encoder driving the outer iteration. Receives the original scope passed to ``start(scope:)``.
    ///   - downstream: Encoder driving the inner iteration. Receives the lifted scope per upstream probe.
    ///   - upstreamBudget: Maximum number of upstream probes pulled per ``start(scope:)`` call. Each upstream probe triggers one ``lift`` invocation (a generator materialisation) plus a downstream search, so this caps the most expensive part of the composition. Pass a larger value when the upstream domain is small relative to the budget.
    ///   - lift: Closure that materialises the upstream probe and constructs the downstream scope. Returns `nil` to skip the upstream probe (for example when the materialisation fails).
    init(
        name: EncoderName,
        upstream: any GraphEncoder,
        downstream: any GraphEncoder,
        upstreamBudget: Int = 15,
        lift: @escaping (EncoderProbe, TransformationScope) -> TransformationScope?
    ) {
        self.name = name
        self.upstream = upstream
        self.downstream = downstream
        self.upstreamBudget = upstreamBudget
        self.lift = lift
    }

    /// Convergence records from the upstream encoder.
    ///
    /// The downstream encoder's records are scoped to the lifted graph and meaningless on the live graph after acceptance — they are deliberately not exposed.
    var convergenceRecords: [Int: ConvergedOrigin] {
        upstream.convergenceRecords
    }

    mutating func start(scope: TransformationScope) {
        originalScope = scope
        currentUpstreamProbe = nil
        downstreamActive = false
        upstreamProbesUsed = 0
        upstream.start(scope: scope)
    }

    mutating func nextProbe(lastAccepted: Bool) -> EncoderProbe? {
        // Drain the active downstream first.
        if downstreamActive {
            if let downstreamProbe = downstream.nextProbe(lastAccepted: lastAccepted) {
                guard let upstreamProbe = currentUpstreamProbe else { return nil }
                return wrap(downstreamProbe: downstreamProbe, upstreamProbe: upstreamProbe)
            }
            downstreamActive = false
        }

        // Advance upstream until we find one whose lift produces at least one downstream probe,
        // or until the upstream budget is exhausted. The budget caps the number of upstream probes
        // that contributed to a *valid* lift — failed lifts (`lift` returns nil) do not count
        // because they incur no downstream materialisation cost.
        guard let parent = originalScope else { return nil }
        while upstreamProbesUsed < upstreamBudget {
            guard let upstreamProbe = upstream.nextProbe(lastAccepted: false) else { return nil }
            guard let downstreamScope = lift(upstreamProbe, parent) else { continue }
            upstreamProbesUsed += 1
            downstream.start(scope: downstreamScope)
            downstreamActive = true
            currentUpstreamProbe = upstreamProbe
            if let firstDownstreamProbe = downstream.nextProbe(lastAccepted: false) {
                return wrap(downstreamProbe: firstDownstreamProbe, upstreamProbe: upstreamProbe)
            }
            downstreamActive = false
        }
        return nil
    }

    /// Resets the composition to idle when a mid-pass structural acceptance has updated the live sequence.
    ///
    /// The composition caches the pre-dispatch scope, the in-flight upstream probe, and the downstream iterator. After any accepted probe triggers a reshape or full rebuild, all three are stale — the upstream binary search was calibrated to the old sequence, the lifted downstream scope was built from the old tree, and continuing would emit probes that may not shortlex-precede the new live sequence. Resetting to idle aborts the current pass; the scheduler re-dispatches a fresh composition next cycle.
    mutating func refreshScope(graph _: ChoiceGraph, sequence _: ChoiceSequence) {
        originalScope = nil
        currentUpstreamProbe = nil
        downstreamActive = false
        upstreamProbesUsed = 0
    }

    /// Replaces a downstream probe's mutation with the upstream's mutation, lifted to set ``LeafChange/mayReshape`` to `true`.
    ///
    /// The candidate sequence is the downstream's lifted candidate; the mutation is what the live graph applies on accept (one upstream leaf change that triggers the partial-rebuild splice path via ``ChoiceGraph/applyBindReshape(forLeaf:freshTree:into:)``).
    private func wrap(
        downstreamProbe: EncoderProbe,
        upstreamProbe: EncoderProbe
    ) -> EncoderProbe {
        guard case let .leafValues(upstreamChanges) = upstreamProbe.mutation else {
            // Non-leafValues upstream mutations are not the intended use of this primitive.
            // Pass the upstream mutation through defensively rather than fabricating one.
            return EncoderProbe(
                candidate: downstreamProbe.candidate,
                mutation: upstreamProbe.mutation
            )
        }
        let reshapeChanges = upstreamChanges.map { change in
            LeafChange(
                leafNodeID: change.leafNodeID,
                newValue: change.newValue,
                mayReshape: true
            )
        }
        return EncoderProbe(
            candidate: downstreamProbe.candidate,
            mutation: .leafValues(reshapeChanges)
        )
    }
}
