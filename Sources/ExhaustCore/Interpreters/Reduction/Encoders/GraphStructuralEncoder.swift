//
//  GraphStructuralEncoder.swift
//  Exhaust
//

// MARK: - Graph Structural Encoder

/// Applies a scope-determined structural mutation to the base sequence.
///
/// Handles all pure (stateless) graph operations: removal, replacement, and migration. For most operations the scope fully determines the probe — one scope, one probe, one ``nextProbe(into:lastAccepted:)`` call. The exception is ``RemovalScope/coveringAligned(_:)``, which carries a ``PullBasedCoveringArrayGenerator`` and emits one probe per covering array row until the generator is exhausted or a probe is accepted.
///
/// Permutation (sibling swap) is handled by the stateful ``GraphSwapEncoder``, which supports adaptive rightward extension after a successful swap.
///
/// The operation-specific candidate construction methods are delegated to dedicated extensions:
/// - `GraphStructuralEncoder+Removal.swift`
/// - `GraphStructuralEncoder+Replacement.swift`
/// - `GraphStructuralEncoder+Migration.swift`
struct GraphStructuralEncoder: GraphEncoder {
    /// Set at ``start(scope:)`` from the operation type. Each structural operation reports under its own encoder name for logging and instrumentation.
    private(set) var name: EncoderName = .deletion

    /// Single-shot mutation for non-covering-array operations.
    private var probe: EncoderProbe?

    /// The candidate sequence pre-built at ``start(scope:)`` for single-shot operations.
    private var probeCandidate: ChoiceSequence?

    /// Multi-shot state for covering-array-backed aligned removal. Accessed by ``nextCoveringAlignedProbe()`` in `GraphStructuralEncoder+Removal.swift`.
    var coveringAlignedState: CoveringAlignedState?

    /// True if any replacement candidate was built but rejected by the shortlex gate. When true, the structural relax round may find value in trying the same candidates without the gate.
    var hadReplacementShortlexRejection = false

    /// Tracks the covering-array cursor state for aligned removal probes, persisting across encoder restarts so the next restart resumes where the previous left off.
    struct CoveringAlignedState {
        let scope: CoveringAlignedRemovalScope
        let baseSequence: ChoiceSequence
        let graph: ChoiceGraph
    }

    mutating func start(scope: EncoderInput) {
        probe = nil
        probeCandidate = nil
        coveringAlignedState = nil

        var candidateBuffer: ChoiceSequence = scope.baseSequence
        let sequence = scope.baseSequence
        let graph = scope.graph

        switch scope.transformation.operation {
        case let .remove(removalScope):
            name = .deletion
            switch removalScope {
            case .elements, .subtree:
                probe = buildRemovalProbe(into: &candidateBuffer, scope: removalScope, sequence: sequence, graph: graph)
                if probe != nil { probeCandidate = candidateBuffer }
            case let .coveringAligned(alignedScope):
                coveringAlignedState = CoveringAlignedState(
                    scope: alignedScope,
                    baseSequence: sequence,
                    graph: graph
                )
            }

        case let .replace(replacementScope):
            name = .substitution
            probe = buildReplacementProbe(into: &candidateBuffer, scope: replacementScope, sequence: sequence, graph: graph)
            if probe != nil { probeCandidate = candidateBuffer }

        case let .migrate(migrationScope):
            name = .migration
            probe = buildMigrationProbe(into: &candidateBuffer, scope: migrationScope, sequence: sequence, graph: graph)
            if probe != nil { probeCandidate = candidateBuffer }

        case .minimize, .exchange, .permute, .reorder:
            break
        }
    }

    mutating func nextProbe(into candidate: inout ChoiceSequence, lastAccepted: Bool) -> EncoderProbe? {
        // Covering-array-backed aligned removal: pull rows until accepted or exhausted.
        if coveringAlignedState != nil {
            if lastAccepted {
                coveringAlignedState = nil
                return nil
            }
            return nextCoveringAlignedProbe(into: &candidate)
        }

        // Single-shot path for all other structural operations.
        defer {
            probe = nil
            probeCandidate = nil
        }
        guard let mutation = probe else { return nil }
        if let storedCandidate = probeCandidate {
            candidate = storedCandidate
        }
        return mutation
    }
}
