//
//  GraphStructuralEncoder.swift
//  Exhaust
//

// MARK: - Graph Structural Encoder

/// Applies a scope-determined structural mutation to the base sequence in a single shot.
///
/// Handles all pure (stateless) graph operations: removal, replacement, swap, and migration. The scope fully determines the probe — there is no search state, no binary search, no convergence tracking. One scope, one probe, one `nextProbe()` call.
///
/// The operation-specific candidate construction methods are delegated to dedicated extensions:
/// - `GraphStructuralEncoder+Removal.swift`
/// - `GraphStructuralEncoder+Replacement.swift`
/// - `GraphStructuralEncoder+Swap.swift`
/// - `GraphStructuralEncoder+Migration.swift`
struct GraphStructuralEncoder: GraphEncoder {
    /// Set at ``start(scope:)`` from the operation type. Each structural operation reports under its own encoder name for logging and instrumentation.
    private(set) var name: EncoderName = .graphDeletion

    private var probe: EncoderProbe?

    mutating func start(scope: TransformationScope) {
        probe = nil

        let sequence = scope.baseSequence
        let graph = scope.graph

        switch scope.transformation.operation {
        case let .remove(removalScope):
            name = .graphDeletion
            probe = buildRemovalProbe(scope: removalScope, sequence: sequence, graph: graph)

        case let .replace(replacementScope):
            name = .graphSubstitution
            probe = buildReplacementProbe(scope: replacementScope, sequence: sequence, tree: scope.tree, graph: graph)

        case let .permute(permutationScope):
            name = .graphSiblingSwap
            probe = buildSwapProbe(scope: permutationScope, sequence: sequence, graph: graph)

        case let .migrate(migrationScope):
            name = .graphMigration
            probe = buildMigrationProbe(scope: migrationScope, sequence: sequence, graph: graph)

        case .minimize, .exchange:
            break
        }
    }

    mutating func nextProbe(lastAccepted: Bool) -> EncoderProbe? {
        defer { probe = nil }
        return probe
    }
}
