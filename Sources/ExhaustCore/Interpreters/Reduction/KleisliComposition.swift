// MARK: - Kleisli Composition

/// Kleisli composition of two composable encoders through a generator lift.
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
/// Conforms to ``ComposableEncoder`` so the scheduler can run it via ``ReductionState/runComposable(_:decoder:positionRange:context:structureChanged:budget:fingerprintGuard:)`` or a manual loop (following the `runRelaxRound` pattern).
public struct KleisliComposition<Output>: ComposableEncoder {
    // MARK: - Configuration

    public let name: EncoderName
    public let phase: ReductionPhase

    /// The upstream composable encoder — proposes mutations at the controlling position.
    var upstream: any ComposableEncoder

    /// The downstream composable encoder — operates in the lifted fibre.
    var downstream: any ComposableEncoder

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

    // MARK: - Fibre telemetry

    /// Number of downstream starts where the fibre was searched exhaustively (≤ 64 combinations).
    public private(set) var fibreExhaustiveStarts = 0
    /// Number of downstream starts where the fibre was searched via pairwise covering (> 64 combinations, ≤ 20 parameters).
    public private(set) var fibrePairwiseStarts = 0
    /// Number of downstream starts where the fibre was too large for covering and ZeroValue fallback ran.
    public private(set) var fibreZeroValueStarts = 0
    /// Maximum fibre size observed across all downstream starts.
    public private(set) var maxObservedFibreSize: UInt64 = 0

    /// Raw convergence records from the previous upstream iteration's downstream, unvalidated.
    ///
    /// Populated when the downstream exhausts. The driver (`runKleisliExploration`) reads this, validates each origin at `floor - 1`, and calls ``setValidatedOrigins(_:)`` with the validated subset (or nil for cold-start).
    public private(set) var pendingTransferOrigins: [Int: ConvergedOrigin]?

    /// Validated convergence origins, set by the driver after `floor - 1` validation.
    ///
    /// The downstream initialization uses these (not the raw pending origins). `nil` means cold-start.
    private var validatedOrigins: [Int: ConvergedOrigin]?

    /// Upstream convergence records accumulated across all upstream iterations.
    private var upstreamConvergenceRecords: [Int: ConvergedOrigin] = [:]

    /// Bit pattern of the previous upstream probe's value, for delta computation.
    public private(set) var previousUpstreamBitPattern: UInt64?

    /// User-value-space delta between the current and previous upstream probe.
    ///
    /// `nil` on the first probe (no previous). For signed integers, computed after zigzag decoding. The driver uses this to decide: delta == 1 → validate and potentially transfer; delta > 1 → cold-start immediately.
    public private(set) var upstreamDelta: UInt64?

    /// Maximum upstream candidates to try.
    private var upstreamBudget = 15
    /// Probes used by the upstream so far.
    private var upstreamProbesUsed = 0

    // MARK: - Initializer

    public init(
        name: EncoderName = .kleisliComposition,
        phase: ReductionPhase = .exploration,
        upstream: any ComposableEncoder,
        downstream: any ComposableEncoder,
        lift: GeneratorLift<Output>,
        rollback: RollbackPolicy,
        upstreamRange: ClosedRange<Int>,
        downstreamRange: ClosedRange<Int>
    ) {
        self.name = name
        self.phase = phase
        self.upstream = upstream
        self.downstream = downstream
        self.lift = lift
        self.rollback = rollback
        self.upstreamRange = upstreamRange
        self.downstreamRange = downstreamRange
    }

    // MARK: - ComposableEncoder

    public func estimatedCost(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) -> Int? {
        guard let upCost = upstream.estimatedCost(
            sequence: sequence, tree: baseTree,
            positionRange: upstreamRange, context: context
        ) else { return nil }
        let downCost = downstream.estimatedCost(
            sequence: sequence, tree: baseTree,
            positionRange: downstreamRange, context: context
        ) ?? 0
        return upCost * (1 + downCost)
    }

    public mutating func start(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) {
        // Do not pass converged origins to the composition — the convergence cache records
        // floors from the standalone pipeline. The composition re-explores those values WITH
        // downstream fibre search. Passing the cache would tell the upstream its current
        // value is at the floor, producing zero probes.
        startInternal(sequence: sequence, tree: tree, convergedOrigins: nil)
    }

    private mutating func startInternal(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        convergedOrigins: [Int: ConvergedOrigin]?
    ) {
        baseSequence = sequence
        baseTree = tree
        context = ReductionContext(convergedOrigins: convergedOrigins)

        upstreamStarted = false
        downstreamActive = false
        liftedSequence = nil
        liftedTree = nil
        lastLiftReport = nil
        pendingTransferOrigins = nil
        validatedOrigins = nil
        upstreamConvergenceRecords = [:]
        previousUpstreamBitPattern = nil
        upstreamDelta = nil
        upstreamProbesUsed = 0
        fibreExhaustiveStarts = 0
        fibrePairwiseStarts = 0
        fibreZeroValueStarts = 0
        maxObservedFibreSize = 0

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

            // Harvest downstream convergence records as pending transfer (unvalidated).
            // The driver validates these at floor - 1 before the next downstream initialization.
            let downRecords = downstream.convergenceRecords
            pendingTransferOrigins = downRecords.isEmpty ? nil : downRecords
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

            // Track upstream value for delta computation
            if let upstreamValue = upstreamProbe[upstreamRange.lowerBound].value {
                let currentBP = upstreamValue.choice.bitPattern64
                if let previousBP = previousUpstreamBitPattern {
                    // Delta in bit-pattern space (zigzag-encoded for signed integers).
                    // For signed: zigzag(n) - zigzag(n-1) == 1 when user values differ by 1.
                    upstreamDelta = currentBP > previousBP ? currentBP - previousBP : previousBP - currentBP
                } else {
                    upstreamDelta = nil // First probe — no previous
                }
                previousUpstreamBitPattern = currentBP
            }

            // Lift the upstream probe — materialize without property check
            guard let liftResult = lift.lift(upstreamProbe) else {
                // Lift rejected — upstream candidate was structurally invalid
                continue
            }

            liftedSequence = liftResult.sequence
            liftedTree = liftResult.tree
            lastLiftReport = liftResult.liftReport

            // Build downstream convergence origins.
            // The global cache provides warm starts from the standalone pipeline.
            // Validated transfer origins (set by the driver via setValidatedOrigins
            // after floor-1 validation) override the global cache at overlapping
            // positions — they are more recent and fibre-specific.
            // When validatedOrigins is nil, the downstream cold-starts from the
            // global cache only.
            var downstreamOrigins = context.convergedOrigins ?? [:]
            if let validated = validatedOrigins {
                for (index, origin) in validated {
                    downstreamOrigins[index] = origin
                }
                // Consume the validated origins — one use per upstream probe
                validatedOrigins = nil
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

            // If the downstream's internal strategy changed (DownstreamPick selected a
            // different alternative), convergence transfer is invalid — cold-start.
            if downstream.isConvergenceTransferSafe == false {
                pendingTransferOrigins = nil
            }

            // Capture fibre telemetry from the downstream encoder.
            if let fibreEncoder = downstream as? FibreCoveringEncoder {
                let fibreSize = fibreEncoder.lastComputedFibreSize
                if fibreSize > maxObservedFibreSize { maxObservedFibreSize = fibreSize }
                if fibreSize <= FibreCoveringEncoder.exhaustiveThreshold {
                    fibreExhaustiveStarts += 1
                } else {
                    fibrePairwiseStarts += 1
                }
            } else if let pick = downstream as? DownstreamPick {
                // DownstreamPick selected an alternative at start() — classify by which one.
                if let selected = pick.selectedEncoder {
                    if selected is FibreCoveringEncoder {
                        let fibreEncoder = selected as! FibreCoveringEncoder
                        let fibreSize = fibreEncoder.lastComputedFibreSize
                        if fibreSize > maxObservedFibreSize { maxObservedFibreSize = fibreSize }
                        if fibreSize <= FibreCoveringEncoder.exhaustiveThreshold {
                            fibreExhaustiveStarts += 1
                        } else {
                            fibrePairwiseStarts += 1
                        }
                    } else {
                        fibreZeroValueStarts += 1
                    }
                }
            }

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

    // MARK: - Driver Interface

    /// Sets the validated convergence origins for the next downstream initialization.
    ///
    /// Called by the driver (`runKleisliExploration`) after validating each pending origin at `floor - 1`. Pass `nil` for cold-start (no transfer). The composition uses these when initializing the downstream encoder — never the raw ``pendingTransferOrigins``.
    public mutating func setValidatedOrigins(_ origins: [Int: ConvergedOrigin]?) {
        validatedOrigins = origins
    }

    // MARK: - Private Helpers

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
