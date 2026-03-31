// MARK: - Composable Encoder Protocol

/// Produces candidate mutations for a position range in the choice sequence.
///
/// Composable encoders are role-agnostic probe strategies. Each operates on a scoped position range and produces candidate sequences — it does not know or care whether it is assigned to the upstream role (proposing fibres), the downstream role (exploring within a fibre), or the standalone role (evaluated directly). The role is determined by where the scheduler places the encoder in the pipeline based on the ``ChoiceDependencyGraph``, not by the encoder itself.
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

    /// Whether convergence records from the previous run are compatible with this run.
    ///
    /// Returns `true` by default — the encoder's semantics have not changed between runs.
    /// ``DownstreamPick`` overrides this to return `false` when a different alternative was
    /// selected, invalidating convergence records from the previous alternative.
    /// ``KleisliComposition`` checks this after ``start()`` and cold-starts the convergence
    /// transfer when it returns `false`.
    var isConvergenceTransferSafe: Bool { get }
}

public extension ComposableEncoder {
    /// Default implementation returning no convergence records.
    var convergenceRecords: [Int: ConvergedOrigin] {
        [:]
    }

    /// Default: convergence transfer is always safe (same encoder semantics across runs).
    var isConvergenceTransferSafe: Bool {
        true
    }

    /// Default cost estimate: nil (no work to do). Conformers should override.
    func estimatedCost(
        sequence _: ChoiceSequence,
        tree _: ChoiceTree,
        positionRange _: ClosedRange<Int>,
        context _: ReductionContext
    ) -> Int? {
        nil
    }

    /// Extracts value spans from a choice sequence, filtered to those whose lower bound falls within the given position range.
    ///
    /// When ``ReductionContext/depthFilter`` is non-nil, further restricts to spans at that bind depth (using ``BindSpanIndex/bindDepth(at:)``). This supports the covariant depth sweep, where spans at a given depth may be non-contiguous across multiple bind regions.
    static func extractFilteredSpans(
        from sequence: ChoiceSequence,
        in positionRange: ClosedRange<Int>,
        context: ReductionContext = ReductionContext()
    ) -> [ChoiceSpan] {
        let allSpans = ChoiceSequence.extractAllValueSpans(from: sequence)
        if let depth = context.depthFilter, let bindIndex = context.bindIndex {
            return allSpans.filter {
                positionRange.contains($0.range.lowerBound)
                    && bindIndex.bindDepth(at: $0.range.lowerBound) == depth
            }
        }
        return allSpans.filter { positionRange.contains($0.range.lowerBound) }
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
    public let dependencyGraph: ChoiceDependencyGraph?

    /// When non-nil, restricts the encoder to value spans at this bind depth.
    ///
    /// Used by the covariant depth sweep, where spans at a given depth may be non-contiguous across multiple bind regions. The encoder applies this filter during span extraction via ``ComposableEncoder/extractFilteredSpans(from:in:context:)``. When `nil`, all spans in the position range are eligible.
    public let depthFilter: Int?

    /// The current reduction cycle number. Used by encoders to timestamp convergence records.
    public let cycle: Int

    /// Per-fingerprint filter validity counts from prior materializations, or `nil` if empty.
    public let filterValidityRates: [UInt64: FilterObservation]?

    public init(
        bindIndex: BindSpanIndex? = nil,
        convergedOrigins: [Int: ConvergedOrigin]? = nil,
        dependencyGraph: ChoiceDependencyGraph? = nil,
        depthFilter: Int? = nil,
        cycle: Int = 0,
        filterValidityRates: [UInt64: FilterObservation]? = nil
    ) {
        self.bindIndex = bindIndex
        self.convergedOrigins = convergedOrigins
        self.dependencyGraph = dependencyGraph
        self.depthFilter = depthFilter
        self.cycle = cycle
        self.filterValidityRates = filterValidityRates
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
        sequence _: ChoiceSequence,
        tree _: ChoiceTree,
        positionRange _: ClosedRange<Int>,
        context _: ReductionContext
    ) {}

    public mutating func nextProbe(lastAccepted _: Bool) -> ChoiceSequence? {
        nil
    }
}
