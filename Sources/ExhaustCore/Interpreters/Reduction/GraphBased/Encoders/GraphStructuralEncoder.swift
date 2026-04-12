//
//  GraphStructuralEncoder.swift
//  Exhaust
//

// MARK: - Graph Structural Encoder

/// Applies a scope-determined structural mutation to the base sequence.
///
/// Handles all pure (stateless) graph operations: removal, replacement, and migration. For most operations the scope fully determines the probe — one scope, one probe, one ``nextProbe(lastAccepted:)`` call. The exception is ``RemovalScope/coveringAligned(_:)``, which carries a ``PullBasedCoveringArrayGenerator`` and emits one probe per covering array row until the generator is exhausted or a probe is accepted.
///
/// Permutation (sibling swap) is handled by the stateful ``GraphSwapEncoder``, which supports adaptive rightward extension after a successful swap.
///
/// The operation-specific candidate construction methods are delegated to dedicated extensions:
/// - `GraphStructuralEncoder+Removal.swift`
/// - `GraphStructuralEncoder+Replacement.swift`
/// - `GraphStructuralEncoder+Migration.swift`
struct GraphStructuralEncoder: GraphEncoder {
    /// Set at ``start(scope:)`` from the operation type. Each structural operation reports under its own encoder name for logging and instrumentation.
    private(set) var name: EncoderName = .graphDeletion

    /// Single-shot probe for non-covering-array operations.
    private var probe: EncoderProbe?

    /// Multi-shot state for covering-array-backed aligned removal. Accessed by ``nextCoveringAlignedProbe()`` in `GraphStructuralEncoder+Removal.swift`.
    var coveringAlignedState: CoveringAlignedState?

    /// Mutable state for the covering-array-backed aligned removal encoder.
    struct CoveringAlignedState {
        let scope: CoveringAlignedRemovalScope
        let baseSequence: ChoiceSequence
        let graph: ChoiceGraph
    }

    mutating func start(scope: TransformationScope) {
        probe = nil
        coveringAlignedState = nil

        let sequence = scope.baseSequence
        let graph = scope.graph

        switch scope.transformation.operation {
        case let .remove(removalScope):
            name = .graphDeletion
            switch removalScope {
            case .elements, .subtree:
                probe = buildRemovalProbe(scope: removalScope, sequence: sequence, graph: graph)
            case let .coveringAligned(alignedScope):
                coveringAlignedState = CoveringAlignedState(
                    scope: alignedScope,
                    baseSequence: sequence,
                    graph: graph
                )
            }

        case let .replace(replacementScope):
            name = .graphSubstitution
            probe = buildReplacementProbe(scope: replacementScope, sequence: sequence, graph: graph)

        case let .migrate(migrationScope):
            name = .graphMigration
            probe = buildMigrationProbe(scope: migrationScope, sequence: sequence, graph: graph)

        case .minimize, .exchange, .permute:
            break
        }
    }

    mutating func nextProbe(lastAccepted: Bool) -> EncoderProbe? {
        // Covering-array-backed aligned removal: pull rows until accepted or exhausted.
        if coveringAlignedState != nil {
            if lastAccepted {
                coveringAlignedState = nil
                return nil
            }
            return nextCoveringAlignedProbe()
        }

        // Single-shot path for all other structural operations.
        defer { probe = nil }
        return probe
    }
}
