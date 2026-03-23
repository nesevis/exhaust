// MARK: - Composable Encoder Protocol

/// Produces candidate mutations for a position range in the choice sequence.
///
/// Composable encoders are the primitives of the horizontal/vertical reduction algebra. Each operates on a scoped position range — agnostic to whether that range represents a horizontal role (upstream of a composition, proposing base morphisms between fibres) or a vertical role (downstream, searching within a fibre). The role is determined by the position's relationship in the ``ChoiceDependencyGraph``, not by the encoder itself.
///
/// ## Interface Changes from `AdaptiveEncoder`
///
/// - `TargetSet` → `positionRange`: the CDG provides a range; the encoder derives its own targets.
/// - `tree` added: branch promotion/pivot encoders need it; eliminates the `currentTree` side channel.
/// - `convergedOrigins` → `context`: bundles converged origins, bind index, and DAG.
/// - `nextProbe`, `lastAccepted`, and `convergenceRecords` are unchanged.
///
/// ## Composability
///
/// A ``KleisliComposition`` composes two composable encoders through a ``GeneratorLift``. The upstream encoder's output is lifted (materialized without property check) to produce a fresh `(sequence, tree)` for the downstream encoder. The property is checked only on the downstream's final output.
public protocol ComposableEncoder {
    /// Typed identifier for dominance pruning and logging.
    var name: EncoderName { get }

    /// Which phase this encoder belongs to.
    var phase: ReductionPhase { get }

    /// Estimates the number of probes this encoder will generate for the given
    /// position range, or returns `nil` if the encoder has no applicable targets
    /// and should be skipped entirely.
    func estimatedCost(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) -> Int?

    /// Initializes internal state for a new encoding pass.
    ///
    /// Called once by the scheduler before the probe loop begins, or once per upstream probe in a ``KleisliComposition`` (where the downstream encoder is re-initialized on the lifted sequence after each upstream candidate).
    mutating func start(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    )

    /// Produces the next probe given feedback on the previous one.
    ///
    /// - Parameter lastAccepted: Whether the previous probe was accepted. Ignored on the first call after ``start(sequence:tree:positionRange:context:)``.
    /// - Returns: The next candidate to try, or `nil` when converged.
    mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence?

    /// Convergence records accumulated during the probe loop.
    ///
    /// Each entry maps a flat sequence index to the ``ConvergedOrigin`` at which the search converged.
    var convergenceRecords: [Int: ConvergedOrigin] { get }
}

public extension ComposableEncoder {
    /// Default implementation returning no convergence records.
    var convergenceRecords: [Int: ConvergedOrigin] {
        [:]
    }

    /// Default cost estimate: nil (no work to do). Conformers should override.
    func estimatedCost(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) -> Int? {
        nil
    }

    /// Extracts value spans from a choice sequence, filtered to those whose lower bound falls within the given position range.
    ///
    /// Shared helper for ``ComposableEncoder`` conformers that derive their targets from a position range rather than a pre-extracted ``TargetSet``. Equivalent to the extraction logic in ``LegacyEncoderAdapter``.
    static func extractFilteredSpans(
        from sequence: ChoiceSequence,
        in positionRange: ClosedRange<Int>
    ) -> [ChoiceSpan] {
        ChoiceSequence.extractAllValueSpans(from: sequence)
            .filter { positionRange.contains($0.range.lowerBound) }
    }
}

// MARK: - Reduction Context

/// Shared state passed to composable encoders without coupling to ``ReductionState``.
public struct ReductionContext {
    /// The bind span index, or `nil` if the generator has no binds.
    public let bindIndex: BindSpanIndex?

    /// Cached convergence bounds from prior cycles, or `nil` if empty.
    public let convergedOrigins: [Int: ConvergedOrigin]?

    /// The choice dependency graph, or `nil` if not available.
    public let dag: ChoiceDependencyGraph?

    public init(
        bindIndex: BindSpanIndex? = nil,
        convergedOrigins: [Int: ConvergedOrigin]? = nil,
        dag: ChoiceDependencyGraph? = nil
    ) {
        self.bindIndex = bindIndex
        self.convergedOrigins = convergedOrigins
        self.dag = dag
    }
}

// MARK: - Identity Composable Encoder

/// A composable encoder that produces no probes — the identity element of the composition algebra.
///
/// Used in ``KleisliComposition`` to express standalone phases: `KleisliComposition(upstream: .identity, downstream: encoder, ...)` runs only the downstream encoder, and vice versa.
public struct IdentityComposableEncoder: ComposableEncoder {
    public let name: EncoderName
    public let phase: ReductionPhase

    public init(name: EncoderName = .kleisliComposition, phase: ReductionPhase = .exploration) {
        self.name = name
        self.phase = phase
    }

    public mutating func start(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) {}

    public mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        nil
    }
}

// MARK: - Legacy Encoder Adapter

/// Bridges an existing ``AdaptiveEncoder`` into the ``ComposableEncoder`` protocol.
///
/// Translates `positionRange` to `TargetSet` by extracting value spans within the range from the sequence. This lets existing encoders participate in ``KleisliComposition`` without internal changes. Temporary — will be removed once all encoders conform to ``ComposableEncoder`` natively.
///
/// Uses `any AdaptiveEncoder` (existential) — acceptable for the exploration leg (325 probes budget, not a hot path).
public struct LegacyEncoderAdapter: ComposableEncoder {
    public var inner: any AdaptiveEncoder
    public var name: EncoderName { inner.name }
    public var phase: ReductionPhase { inner.phase }

    public init(inner: any AdaptiveEncoder) {
        self.inner = inner
    }

    public func estimatedCost(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) -> Int? {
        inner.estimatedCost(sequence: sequence, bindIndex: context.bindIndex)
    }

    public mutating func start(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) {
        let allSpans = ChoiceSequence.extractAllValueSpans(from: sequence)
        let filteredSpans = allSpans.filter { positionRange.contains($0.range.lowerBound) }
        inner.start(
            sequence: sequence,
            targets: .spans(filteredSpans),
            convergedOrigins: context.convergedOrigins
        )
    }

    public mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        inner.nextProbe(lastAccepted: lastAccepted)
    }

    public var convergenceRecords: [Int: ConvergedOrigin] {
        inner.convergenceRecords
    }
}
