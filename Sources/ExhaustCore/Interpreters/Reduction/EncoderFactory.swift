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

    // MARK: - Types

    /// The four value minimization encoder instances, passed by the caller.
    struct ValueEncoders {
        let zeroValue: ZeroValueEncoder
        let binarySearchToZero: BinarySearchToSemanticSimplestEncoder
        let binarySearchToTarget: BinarySearchToRangeMinimumEncoder
        let reduceFloat: ReduceFloatEncoder
    }
}
