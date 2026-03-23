// MARK: - Morphism Descriptor

/// Describes a single reduction morphism: an encoder paired with a decoder mode.
///
/// A morphism in OptRed is an (enc, dec) pair. The encoder proposes candidates; the decoder
/// validates them. The descriptor bundles these with scheduling metadata (budget, role, dominance).
///
/// ## Dominance
///
/// ``dominates`` expresses priority ordering between descriptors. When a descriptor's encoder
/// accepts a probe, the scheduler suppresses all descriptors it dominates. This replaces
/// hand-coded multi-tier orchestration with declarative dominance chains.
///
/// Example: the ProductSpaceBatch three-tier pattern becomes:
/// ```
/// [
///   (encoder: batch, decoder: .guided,   dominates: [1, 2]),
///   (encoder: regime, decoder: .exact,   dominates: [2]),
///   (encoder: batch, decoder: .prng,     dominates: [])
/// ]
/// ```
///
/// ## Decoder Parameterisation
///
/// The same encoder with different decoder modes produces a family of morphisms.
/// Varying the decoder mode is one of the two parameterisation axes (the other is
/// encoder configuration, handled per-type at construction time).
public struct MorphismDescriptor {
    /// The encoder that produces candidate probes.
    public let encoder: any ComposableEncoder

    /// How to build the ``SequenceDecoder`` for this morphism's probes.
    public let decoderFactory: @Sendable () -> SequenceDecoder

    /// Maximum number of materializations for this morphism.
    public let probeBudget: Int

    /// Whether structural changes are expected (triggers BindSpanIndex rebuild on acceptance).
    public let structureChanged: Bool

    /// Indices of other descriptors in the same chain that are suppressed when this one accepts.
    public let dominates: [Int]

    /// Maximum number of times to re-run this morphism with fresh decoder instances.
    ///
    /// Used for PRNG retries: each retry gets a fresh decoder (with a different salt).
    /// The ``retrySaltBase`` is incremented per retry.
    public let maxRetries: Int

    /// Base salt for PRNG decoder retries. Incremented by the retry index.
    public let retrySaltBase: UInt64

    /// Structural fingerprint guard for Phase 2 boundary enforcement.
    ///
    /// When non-nil, each acceptance is checked against this fingerprint. If the fingerprint
    /// changes (structural boundary crossed), the acceptance is rolled back.
    public let fingerprintGuard: StructuralFingerprint?

    public init(
        encoder: any ComposableEncoder,
        decoderFactory: @escaping @Sendable () -> SequenceDecoder,
        probeBudget: Int,
        structureChanged: Bool,
        dominates: [Int] = [],
        maxRetries: Int = 1,
        retrySaltBase: UInt64 = 0,
        fingerprintGuard: StructuralFingerprint? = nil
    ) {
        self.encoder = encoder
        self.decoderFactory = decoderFactory
        self.probeBudget = probeBudget
        self.structureChanged = structureChanged
        self.dominates = dominates
        self.maxRetries = maxRetries
        self.retrySaltBase = retrySaltBase
        self.fingerprintGuard = fingerprintGuard
    }
}
