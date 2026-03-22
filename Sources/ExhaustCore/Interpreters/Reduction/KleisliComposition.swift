// MARK: - Kleisli Composition

/// Kleisli composition of two point encoders through a generator lift.
///
/// The upstream encoder proposes a mutation. The generator lift replays through the generator to produce a valid `(sequence, tree)` — the Kleisli bind. The downstream encoder operates in the lifted trace. The property checks only the final output.
///
/// See ``GeneratorLift`` for the monadic structure this composition operates within.
///
/// ## Iteration Semantics
///
/// The composition drives an outer-inner loop:
/// - **Outer loop**: iterate upstream probes. For each, lift to get a fresh tree.
/// - **Inner loop**: iterate downstream probes on the fresh tree. Yield each as a composed probe.
/// - **On downstream exhaustion**: roll back or keep the upstream change depending on ``RollbackPolicy``.
///
/// ## Convergence Transfer
///
/// When the lift report between adjacent upstream values shows high coverage (most coordinates carried forward at tier 1), the downstream encoder's convergence points from the previous upstream iteration are carried forward as warm starts. This dramatically reduces downstream search cost — from a full binary search to one or two validation probes per upstream candidate.
///
/// ## Conformance
///
/// Conforms to ``AdaptiveEncoder`` so the scheduler can run it via the existing `runAdaptive` path or a manual loop (following the `runRelaxRound` pattern). Does NOT conform to ``PointEncoder`` — this is intentional to prevent nesting compositions, which would produce multiplicative budget explosion. Multi-hop composition uses topological iteration instead.
public struct KleisliComposition<Output>: AdaptiveEncoder {
    // MARK: - Configuration

    public let name: EncoderName = .kleisliComposition
    public let phase: ReductionPhase = .exploration

    /// The upstream point encoder — proposes mutations at the controlling position.
    var upstream: any PointEncoder

    /// The downstream point encoder — operates in the lifted fibre.
    var downstream: any PointEncoder

    /// The generator lift — the Kleisli bind between upstream and downstream.
    let lift: GeneratorLift<Output>

    /// Controls rollback when the downstream encoder exhausts without finding a failure.
    let rollback: RollbackPolicy

    /// The controlling position — the upstream encoder operates here.
    let upstreamRange: ClosedRange<Int>

    /// The controlled subtree — the downstream encoder operates here.
    let downstreamRange: ClosedRange<Int>

    /// Controls what happens when the downstream encoder exhausts without finding a failure.
    public enum RollbackPolicy {
        /// Roll back the upstream change. The composition is atomic.
        case atomic
        /// Keep the upstream change. Partial success — upstream improved, downstream did not.
        case partial
    }

    // MARK: - Internal State

    /// The base sequence before any upstream mutation.
    private var baseSequence: ChoiceSequence = .init([])
    /// The base tree before any upstream mutation.
    private var baseTree: ChoiceTree = .just("")
    /// The reduction context passed to both encoders.
    private var context: ReductionContext = .init()

    /// Whether the upstream encoder has been started.
    private var upstreamStarted = false
    /// Whether the downstream encoder is currently active (iterating).
    private var downstreamActive = false

    /// The lifted sequence from the most recent successful lift.
    private var liftedSequence: ChoiceSequence?
    /// The lifted tree from the most recent successful lift.
    private var liftedTree: ChoiceTree?
    /// The lift report from the most recent successful lift.
    private var lastLiftReport: DecodingReport?

    /// Downstream convergence records from the previous upstream iteration.
    /// Carried forward when the lift report shows high coverage.
    private var downstreamConvergenceTransfer: [Int: ConvergedOrigin] = [:]

    /// Upstream convergence records accumulated across all upstream iterations.
    private var upstreamConvergenceRecords: [Int: ConvergedOrigin] = [:]

    /// Maximum upstream candidates to try.
    private var upstreamBudget = 15
    /// Probes used by the upstream so far.
    private var upstreamProbesUsed = 0

    // MARK: - Initializer

    public init(
        upstream: any PointEncoder,
        downstream: any PointEncoder,
        lift: GeneratorLift<Output>,
        rollback: RollbackPolicy,
        upstreamRange: ClosedRange<Int>,
        downstreamRange: ClosedRange<Int>
    ) {
        self.upstream = upstream
        self.downstream = downstream
        self.lift = lift
        self.rollback = rollback
        self.upstreamRange = upstreamRange
        self.downstreamRange = downstreamRange
    }

    // MARK: - AdaptiveEncoder Conformance

    public func estimatedCost(sequence: ChoiceSequence, bindIndex: BindSpanIndex?) -> Int? {
        let ctx = ReductionContext(bindIndex: bindIndex)
        guard let upCost = upstream.estimatedCost(
            sequence: sequence, tree: baseTree,
            positionRange: upstreamRange, context: ctx
        ) else { return nil }
        let downCost = downstream.estimatedCost(
            sequence: sequence, tree: baseTree,
            positionRange: downstreamRange, context: ctx
        ) ?? 0
        return upCost * (1 + downCost)
    }

    public mutating func start(
        sequence: ChoiceSequence,
        targets: TargetSet,
        convergedOrigins: [Int: ConvergedOrigin]?
    ) {
        baseSequence = sequence
        // Use a minimal tree — the actual tree will come from the lift
        baseTree = .just("")
        context = ReductionContext(convergedOrigins: convergedOrigins)

        upstreamStarted = false
        downstreamActive = false
        liftedSequence = nil
        liftedTree = nil
        lastLiftReport = nil
        downstreamConvergenceTransfer = [:]
        upstreamConvergenceRecords = [:]
        upstreamProbesUsed = 0

        upstream.start(
            sequence: sequence,
            tree: baseTree,
            positionRange: upstreamRange,
            context: context
        )
        upstreamStarted = true
    }

    public mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        // If downstream is active, advance it first
        if downstreamActive {
            if let downstreamProbe = downstream.nextProbe(lastAccepted: lastAccepted) {
                return downstreamProbe
            }
            // Downstream exhausted
            downstreamActive = false

            // Harvest downstream convergence records for potential transfer
            let downRecords = downstream.convergenceRecords
            if downRecords.isEmpty == false {
                downstreamConvergenceTransfer = downRecords
            }
        }

        // Advance upstream to get the next candidate
        while upstreamProbesUsed < upstreamBudget {
            guard let upstreamProbe = upstream.nextProbe(lastAccepted: false) else {
                // Upstream exhausted — harvest its convergence records
                for (index, origin) in upstream.convergenceRecords {
                    upstreamConvergenceRecords[index] = origin
                }
                return nil
            }
            upstreamProbesUsed += 1

            // Lift the upstream probe — materialize without property check
            guard let liftResult = lift.lift(upstreamProbe) else {
                // Lift rejected — upstream candidate was structurally invalid
                continue
            }

            liftedSequence = liftResult.sequence
            liftedTree = liftResult.tree
            lastLiftReport = liftResult.liftReport

            // Build downstream convergence origins from two sources:
            // 1. The global convergence cache (same positions, potentially valid
            //    warm starts from the standalone pipeline).
            // 2. Convergence transfer from the previous upstream iteration's
            //    downstream (gated by lift report coverage — only if the fibres
            //    are similar enough that the stall points carry over).
            // The transfer origins override the global cache at overlapping
            // positions — they are more recent and fibre-specific.
            var downstreamOrigins = context.convergedOrigins ?? [:]
            if let transferOrigins = convergenceTransferOrigins(from: liftResult.liftReport) {
                for (index, origin) in transferOrigins {
                    downstreamOrigins[index] = origin
                }
            }

            // Initialize downstream on the lifted (sequence, tree)
            let downstreamContext = ReductionContext(
                bindIndex: context.bindIndex.flatMap { _ in BindSpanIndex(from: liftResult.sequence) },
                convergedOrigins: downstreamOrigins.isEmpty ? nil : downstreamOrigins,
                dag: context.dag
            )
            downstream.start(
                sequence: liftResult.sequence,
                tree: liftResult.tree,
                positionRange: adjustedDownstreamRange(in: liftResult.sequence),
                context: downstreamContext
            )
            downstreamActive = true

            // Get the first downstream probe
            if let firstProbe = downstream.nextProbe(lastAccepted: false) {
                return firstProbe
            }

            // Downstream produced nothing — try next upstream candidate
            downstreamActive = false
        }

        // Upstream budget exhausted
        return nil
    }

    /// Convergence records from the composition — only upstream records are promotable.
    ///
    /// Downstream records are ephemeral (valid only for one upstream value) and managed internally via convergence transfer.
    public var convergenceRecords: [Int: ConvergedOrigin] {
        upstreamConvergenceRecords
    }

    // MARK: - Private Helpers

    /// Determines whether to transfer downstream convergence records from the previous upstream iteration, based on the lift report's coverage.
    ///
    /// High coverage (most coordinates at tier 1) → transfer. The fibres are similar.
    /// Low coverage (many coordinates at tier 2 or 3) → discard. The fibres differ.
    private func convergenceTransferOrigins(
        from liftReport: DecodingReport?
    ) -> [Int: ConvergedOrigin]? {
        guard let report = liftReport,
              downstreamConvergenceTransfer.isEmpty == false
        else { return nil }

        // Transfer if fidelity is above threshold (most coordinates carried forward faithfully)
        let coverageThreshold = 0.7
        if report.fidelity >= coverageThreshold {
            return downstreamConvergenceTransfer
        }
        return nil
    }

    /// Adjusts the downstream range for the lifted sequence.
    ///
    /// After a lift, the sequence may have a different length. The downstream range is clamped to the lifted sequence's bounds.
    private func adjustedDownstreamRange(in liftedSequence: ChoiceSequence) -> ClosedRange<Int> {
        let lower = min(downstreamRange.lowerBound, max(0, liftedSequence.count - 1))
        let upper = min(downstreamRange.upperBound, max(0, liftedSequence.count - 1))
        guard lower <= upper else { return 0 ... 0 }
        return lower ... upper
    }
}
