// MARK: - Encoder Factory

/// Builds ``MorphismDescriptor`` arrays from structural context.
///
/// Centralises encoder selection and ordering. The factory reads the current sequence state,
/// encoder ordering preferences, and structural metadata (CDG, bind index) to emit descriptor
/// arrays that the scheduler processes via ``ReductionState/runDescriptorChain(_:positionRange:context:budget:)``
/// or ``ReductionState/runDescriptorChainDetailed(_:positionRange:context:budget:)``.
///
/// The factory does not execute encoders — it only decides WHICH encoders run, in WHAT order,
/// with WHAT decoder modes. Execution is the scheduler's responsibility.
struct EncoderFactory {

    // MARK: - Value minimization descriptors

    /// Builds descriptors for the four value minimization encoders in the given ordering.
    ///
    /// Used by the leaf-range loop and the covariant depth sweep. Returns descriptors only for
    /// encoders that have applicable targets (non-empty spans or float spans in the range).
    ///
    /// - Parameters:
    ///   - ordering: The encoder slot ordering (move-to-front promoted from prior acceptances).
    ///   - sequence: The current choice sequence (used for span availability checks).
    ///   - encoders: The four value encoder instances.
    ///   - decoder: The decoder for this section (exact for top-level ranges, guided for in-bound ranges).
    ///   - hasValueSpans: Whether any non-float value spans exist in the target range.
    ///   - hasFloatSpans: Whether any float spans exist in the target range.
    ///   - structureChanged: Whether acceptances should trigger bind index rebuild.
    ///   - fingerprintGuard: Structural fingerprint guard for Phase 2 boundary enforcement.
    static func valueMinimizationDescriptors(
        ordering: [ReductionScheduler.ValueEncoderSlot],
        encoders: ValueEncoders,
        decoder: SequenceDecoder,
        hasValueSpans: Bool,
        hasFloatSpans: Bool,
        structureChanged: Bool,
        fingerprintGuard: StructuralFingerprint?,
        budgetCap: Int
    ) -> [MorphismDescriptor] {
        ordering.compactMap { slot in
            let encoder: any ComposableEncoder
            switch slot {
            case .zeroValue where hasValueSpans:
                encoder = encoders.zeroValue
            case .binarySearchToZero where hasValueSpans:
                encoder = encoders.binarySearchToZero
            case .binarySearchToTarget where hasValueSpans:
                encoder = encoders.binarySearchToTarget
            case .reduceFloat where hasFloatSpans:
                encoder = encoders.reduceFloat
            default:
                return nil
            }
            return MorphismDescriptor(
                encoder: encoder,
                decoderFactory: { decoder },
                probeBudget: budgetCap,
                structureChanged: structureChanged,
                fingerprintGuard: fingerprintGuard
            )
        }
    }

    /// Builds descriptors for the redistribution section (tandem + cross-stage).
    static func redistributionDescriptors(
        tandemEncoder: RedistributeByTandemReductionEncoder,
        redistributeEncoder: RedistributeAcrossValueContainersEncoder,
        decoder: SequenceDecoder,
        structureChanged: Bool,
        budgetCap: Int
    ) -> [MorphismDescriptor] {
        [
            MorphismDescriptor(
                encoder: tandemEncoder,
                decoderFactory: { decoder },
                probeBudget: budgetCap,
                structureChanged: structureChanged
            ),
            MorphismDescriptor(
                encoder: redistributeEncoder,
                decoderFactory: { decoder },
                probeBudget: budgetCap,
                structureChanged: structureChanged
            ),
        ]
    }

    /// Builds the three-descriptor dominance chain for ProductSpaceBatch (≤ 3 bind axes).
    ///
    /// Tier 1 (guided) → Regime probe (exact) → Tier 2 (PRNG retries, largest-fibre-first).
    /// Tier 1 dominates both regime probe and Tier 2. Regime probe dominates Tier 2.
    static func productSpaceBatchDescriptors(
        allCandidates: [ChoiceSequence],
        tier2Candidates: [ChoiceSequence],
        guidedDecoder: SequenceDecoder,
        cycle: Int
    ) -> [MorphismDescriptor] {
        [
            MorphismDescriptor(
                encoder: PrecomputedComposableEncoder(
                    name: .productSpaceBatch,
                    phase: .valueMinimization,
                    candidates: allCandidates
                ),
                decoderFactory: { guidedDecoder },
                probeBudget: allCandidates.count,
                structureChanged: true,
                dominates: [1, 2]
            ),
            MorphismDescriptor(
                encoder: RegimeProbeEncoder(),
                decoderFactory: { .exact() },
                probeBudget: 1,
                structureChanged: true,
                dominates: [2]
            ),
            MorphismDescriptor(
                encoder: PrecomputedComposableEncoder(
                    name: .productSpaceBatch,
                    phase: .valueMinimization,
                    candidates: tier2Candidates
                ),
                decoderFactory: { .guided(
                    fallbackTree: nil, usePRNGFallback: true,
                    prngSalt: UInt64(cycle * 4)
                ) },
                probeBudget: tier2Candidates.count,
                structureChanged: true,
                maxRetries: 4,
                retrySaltBase: UInt64(cycle * 4)
            ),
        ]
    }

    // MARK: - Composition descriptors

    /// Builds ``KleisliComposition`` instances for each CDG reduction edge.
    ///
    /// Each edge produces a composition wiring an upstream encoder (binary search on the
    /// bind-inner value) to a downstream encoder (fibre covering) through a generator lift.
    /// The caller runs the compositions with warm-start validation in ``runKleisliExploration``.
    static func compositionDescriptors<Output>(
        edges: [ReductionEdge],
        gen: FreerMonad<ReflectiveOperation, Output>,
        tree: ChoiceTree,
        fallbackTree: ChoiceTree?,
        budgetPerEdge: Int
    ) -> [KleisliComposition<Output>] {
        edges.map { edge in
            KleisliComposition(
                upstream: BinarySearchToSemanticSimplestEncoder(),
                downstream: FibreCoveringEncoder(),
                lift: GeneratorLift(gen: gen, mode: .guided(fallbackTree: fallbackTree ?? tree)),
                rollback: .atomic,
                upstreamRange: edge.upstreamRange,
                downstreamRange: edge.downstreamRange
            )
        }
    }

    // MARK: - Fibre size prediction

    /// Predicts the downstream fibre size for a CDG edge from the current sequence state.
    ///
    /// Walks value positions in the downstream range, reads their domain sizes from ``validRange``,
    /// and returns the product. This is the same computation ``FibreCoveringEncoder`` performs at
    /// ``ComposableEncoder/start(sequence:tree:positionRange:context:)`` time — but computed on the
    /// CURRENT sequence before the upstream mutation, not on the lifted sequence after it.
    ///
    /// The prediction is accurate when the downstream domains are independent of the upstream value
    /// (structurally constant edges). For data-dependent edges, the actual fibre size after lift may differ.
    struct FibrePrediction {
        /// Product of domain sizes across downstream value positions.
        let predictedSize: UInt64
        /// Number of value parameters in the downstream range.
        let parameterCount: Int
        /// Predicted encoder mode based on thresholds.
        let predictedMode: Mode

        enum Mode: Equatable {
            case exhaustive    // predictedSize ≤ 64
            case pairwise      // predictedSize > 64, parameterCount ≤ 20
            case tooLarge      // parameterCount > 20 or overflow
        }
    }

    static func predictFibreSize(
        sequence: ChoiceSequence,
        downstreamRange: ClosedRange<Int>
    ) -> FibrePrediction {
        var parameterCount = 0
        var product: UInt64 = 1
        var overflowed = false

        for index in downstreamRange {
            guard index < sequence.count else { break }
            guard let value = sequence[index].value,
                  let validRange = value.validRange
            else { continue }

            parameterCount += 1
            let domainSize = validRange.upperBound - validRange.lowerBound + 1
            let (result, overflow) = product.multipliedReportingOverflow(by: domainSize)
            if overflow || result > UInt64.max / 2 {
                overflowed = true
                break
            }
            product = result
        }

        let predictedSize = overflowed ? UInt64.max : product
        let mode: FibrePrediction.Mode
        if overflowed || parameterCount > 20 {
            mode = .tooLarge
        } else if predictedSize <= FibreCoveringEncoder.exhaustiveThreshold {
            mode = .exhaustive
        } else {
            mode = .pairwise
        }

        return FibrePrediction(
            predictedSize: predictedSize,
            parameterCount: parameterCount,
            predictedMode: mode
        )
    }

    /// Predicts downstream fibre size at the upstream's reduction target via a discovery lift.
    ///
    /// Sets the upstream bind-inner value to its reduction target (range minimum or semantic simplest),
    /// materialises the generator to produce a fresh downstream sequence, then reads the fibre size
    /// from the lifted result. This is one materialisation — the "discovery budget" from the planning
    /// document.
    ///
    /// Returns the naive prediction (from the current sequence) if the discovery lift fails.
    static func predictFibreSizeAtTarget<Output>(
        sequence: ChoiceSequence,
        edge: ReductionEdge,
        gen: FreerMonad<ReflectiveOperation, Output>,
        tree: ChoiceTree,
        fallbackTree: ChoiceTree?
    ) -> FibrePrediction {
        // Read the upstream value and compute its reduction target.
        let upstreamIndex = edge.upstreamRange.lowerBound
        guard upstreamIndex < sequence.count,
              let upstreamValue = sequence[upstreamIndex].value
        else {
            return predictFibreSize(sequence: sequence, downstreamRange: edge.downstreamRange)
        }

        let isWithinRecordedRange = upstreamValue.isRangeExplicit && upstreamValue.choice.fits(in: upstreamValue.validRange)
        let targetBitPattern = isWithinRecordedRange
            ? upstreamValue.choice.reductionTarget(in: upstreamValue.validRange)
            : upstreamValue.choice.semanticSimplest.bitPattern64

        // If the upstream is already at its target, the current-sequence prediction is exact.
        if targetBitPattern == upstreamValue.choice.bitPattern64 {
            return predictFibreSize(sequence: sequence, downstreamRange: edge.downstreamRange)
        }

        // Build a modified sequence with the upstream set to its target.
        var modified = sequence
        modified[upstreamIndex] = .value(.init(
            choice: ChoiceValue(
                upstreamValue.choice.tag.makeConvertible(bitPattern64: targetBitPattern),
                tag: upstreamValue.choice.tag
            ),
            validRange: upstreamValue.validRange,
            isRangeExplicit: upstreamValue.isRangeExplicit
        ))

        // Discovery lift: materialise at the target upstream value.
        let liftResult = ReductionMaterializer.materialize(
            gen,
            prefix: modified,
            mode: .exact,
            fallbackTree: fallbackTree ?? tree
        )

        switch liftResult {
        case let .success(_, freshTree, _):
            let freshSequence = ChoiceSequence(freshTree)
            // Read the fibre size from the lifted sequence.
            // The downstream range may shift in the lifted sequence (structural changes).
            // Use the edge's downstream range clamped to the fresh sequence length.
            let clampedRange = edge.downstreamRange.lowerBound ... min(edge.downstreamRange.upperBound, max(0, freshSequence.count - 1))
            return predictFibreSize(sequence: freshSequence, downstreamRange: clampedRange)
        case .rejected, .failed:
            // Discovery lift failed (target value out of range or materialisation error).
            // Fall back to the naive prediction from the current sequence.
            return predictFibreSize(sequence: sequence, downstreamRange: edge.downstreamRange)
        }
    }

    // MARK: - Types

    /// The four value minimization encoder instances, passed by the caller.
    struct ValueEncoders {
        let zeroValue: ZeroValueEncoder
        let binarySearchToZero: BinarySearchToSemanticSimplestEncoder
        let binarySearchToTarget: BinarySearchToRangeMinimumEncoder
        let reduceFloat: ReduceFloatEncoder
    }
}
