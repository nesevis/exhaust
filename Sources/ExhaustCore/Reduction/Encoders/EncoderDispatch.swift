/// Routes ``GraphEncoder`` calls through concrete copy-on-write boxes, avoiding existential dispatch and enum payload reconstruction on the per-probe path.
///
/// Each case keeps its concrete encoder in reusable reference storage. Mutating calls detach shared storage before advancing the search, preserving independent progress when a dispatch handle is copied.
enum EncoderDispatch {
    case structural(EncoderStorage<GraphStructuralEncoder>)
    case value(EncoderStorage<GraphValueEncoder>)
    case redistribution(EncoderStorage<GraphRedistributionEncoder>)
    case lockstep(EncoderStorage<GraphLockstepEncoder>)
    case relation(EncoderStorage<GraphRelationEncoder>)
    case stagedJoint(EncoderStorage<StagedJointEncoder>)
    case swap(EncoderStorage<GraphSwapEncoder>)
    case windowRemoval(EncoderStorage<GraphWindowRemovalEncoder>)
    case reorder(EncoderStorage<GraphReorderEncoder>)
    case laneCollapse(EncoderStorage<GraphLaneCollapseEncoder>)
    case depthCollapse(EncoderStorage<GraphDepthCollapseEncoder>)
    case binarySearch(EncoderStorage<GraphBinarySearchEncoder>)
    case boundValueCovering(EncoderStorage<GraphBoundValueCoveringEncoder>)
    case liftedStage(EncoderStorage<GraphLiftedStageEncoder>)
    case composed(EncoderStorage<GraphComposedEncoder>)

    /// Selects a concrete storage case once at construction, so subsequent probes use enum dispatch rather than existential calls.
    ///
    /// Generic input lets concrete callers specialize away the type switch and temporary existential storage. Erased encoders still work through implicit existential opening.
    ///
    /// Existing dispatch handles preserve their storage and copy-on-write behavior. Every other conformer must have a concrete case here; an unsupported encoder fails a precondition instead of silently falling back to existential dispatch.
    init(_ encoder: some GraphEncoder) {
        switch encoder {
            case let encoder as Self:
                self = encoder
            case let encoder as GraphStructuralEncoder:
                self = .structural(EncoderStorage(encoder))
            case let encoder as GraphValueEncoder:
                self = .value(EncoderStorage(encoder))
            case let encoder as GraphRedistributionEncoder:
                self = .redistribution(EncoderStorage(encoder))
            case let encoder as GraphLockstepEncoder:
                self = .lockstep(EncoderStorage(encoder))
            case let encoder as GraphRelationEncoder:
                self = .relation(EncoderStorage(encoder))
            case let encoder as StagedJointEncoder:
                self = .stagedJoint(EncoderStorage(encoder))
            case let encoder as GraphSwapEncoder:
                self = .swap(EncoderStorage(encoder))
            case let encoder as GraphWindowRemovalEncoder:
                self = .windowRemoval(EncoderStorage(encoder))
            case let encoder as GraphReorderEncoder:
                self = .reorder(EncoderStorage(encoder))
            case let encoder as GraphLaneCollapseEncoder:
                self = .laneCollapse(EncoderStorage(encoder))
            case let encoder as GraphDepthCollapseEncoder:
                self = .depthCollapse(EncoderStorage(encoder))
            case let encoder as GraphBinarySearchEncoder:
                self = .binarySearch(EncoderStorage(encoder))
            case let encoder as GraphBoundValueCoveringEncoder:
                self = .boundValueCovering(EncoderStorage(encoder))
            case let encoder as GraphLiftedStageEncoder:
                self = .liftedStage(EncoderStorage(encoder))
            case let encoder as GraphComposedEncoder:
                self = .composed(EncoderStorage(encoder))
            default:
                preconditionFailure("Unsupported graph encoder: \(type(of: encoder))")
        }
    }
}

extension EncoderDispatch: GraphEncoder {
    /// The staged session advances descriptors before touching its candidate buffer; other encoders retain their normal probe path.
    ///
    /// Restores each concrete case explicitly so dispatch consumption does not retain the staged box during its uniqueness check.
    mutating func nextStagedJointProbe(lastAccepted: Bool) -> StagedJointEncoder.Probe? {
        switch consume self {
            case var .stagedJoint(encoder):
                Self.makeUnique(&encoder)
                let probe = encoder.value.nextSparseProbe(lastAccepted: lastAccepted)
                self = .stagedJoint(encoder)
                return probe
            case let .structural(encoder):
                self = .structural(encoder)
                return nil
            case let .value(encoder):
                self = .value(encoder)
                return nil
            case let .redistribution(encoder):
                self = .redistribution(encoder)
                return nil
            case let .lockstep(encoder):
                self = .lockstep(encoder)
                return nil
            case let .relation(encoder):
                self = .relation(encoder)
                return nil
            case let .swap(encoder):
                self = .swap(encoder)
                return nil
            case let .windowRemoval(encoder):
                self = .windowRemoval(encoder)
                return nil
            case let .reorder(encoder):
                self = .reorder(encoder)
                return nil
            case let .laneCollapse(encoder):
                self = .laneCollapse(encoder)
                return nil
            case let .depthCollapse(encoder):
                self = .depthCollapse(encoder)
                return nil
            case let .binarySearch(encoder):
                self = .binarySearch(encoder)
                return nil
            case let .boundValueCovering(encoder):
                self = .boundValueCovering(encoder)
                return nil
            case let .liftedStage(encoder):
                self = .liftedStage(encoder)
                return nil
            case let .composed(encoder):
                self = .composed(encoder)
                return nil
        }
    }

    var name: EncoderName {
        switch self {
            case let .structural(encoder):
                encoder.value.name
            case let .value(encoder):
                encoder.value.name
            case let .redistribution(encoder):
                encoder.value.name
            case let .lockstep(encoder):
                encoder.value.name
            case let .relation(encoder):
                encoder.value.name
            case let .stagedJoint(encoder):
                encoder.value.name
            case let .swap(encoder):
                encoder.value.name
            case let .windowRemoval(encoder):
                encoder.value.name
            case let .reorder(encoder):
                encoder.value.name
            case let .laneCollapse(encoder):
                encoder.value.name
            case let .depthCollapse(encoder):
                encoder.value.name
            case let .binarySearch(encoder):
                encoder.value.name
            case let .boundValueCovering(encoder):
                encoder.value.name
            case let .liftedStage(encoder):
                encoder.value.name
            case let .composed(encoder):
                encoder.value.name
        }
    }

    mutating func start(scope: EncoderInput) {
        switch consume self {
            case var .structural(encoder):
                Self.makeUnique(&encoder)
                encoder.value.start(scope: scope)
                self = .structural(encoder)
            case var .value(encoder):
                Self.makeUnique(&encoder)
                encoder.value.start(scope: scope)
                self = .value(encoder)
            case var .redistribution(encoder):
                Self.makeUnique(&encoder)
                encoder.value.start(scope: scope)
                self = .redistribution(encoder)
            case var .lockstep(encoder):
                Self.makeUnique(&encoder)
                encoder.value.start(scope: scope)
                self = .lockstep(encoder)
            case var .relation(encoder):
                Self.makeUnique(&encoder)
                encoder.value.start(scope: scope)
                self = .relation(encoder)
            case var .stagedJoint(encoder):
                Self.makeUnique(&encoder)
                encoder.value.start(scope: scope)
                self = .stagedJoint(encoder)
            case var .swap(encoder):
                Self.makeUnique(&encoder)
                encoder.value.start(scope: scope)
                self = .swap(encoder)
            case var .windowRemoval(encoder):
                Self.makeUnique(&encoder)
                encoder.value.start(scope: scope)
                self = .windowRemoval(encoder)
            case var .reorder(encoder):
                Self.makeUnique(&encoder)
                encoder.value.start(scope: scope)
                self = .reorder(encoder)
            case var .laneCollapse(encoder):
                Self.makeUnique(&encoder)
                encoder.value.start(scope: scope)
                self = .laneCollapse(encoder)
            case var .depthCollapse(encoder):
                Self.makeUnique(&encoder)
                encoder.value.start(scope: scope)
                self = .depthCollapse(encoder)
            case var .binarySearch(encoder):
                Self.makeUnique(&encoder)
                encoder.value.start(scope: scope)
                self = .binarySearch(encoder)
            case var .boundValueCovering(encoder):
                Self.makeUnique(&encoder)
                encoder.value.start(scope: scope)
                self = .boundValueCovering(encoder)
            case var .liftedStage(encoder):
                Self.makeUnique(&encoder)
                encoder.value.start(scope: scope)
                self = .liftedStage(encoder)
            case var .composed(encoder):
                Self.makeUnique(&encoder)
                encoder.value.start(scope: scope)
                self = .composed(encoder)
        }
    }

    mutating func nextProbe(into candidate: inout ChoiceSequence, lastAccepted: Bool) -> EncoderProbe? {
        switch consume self {
            case var .structural(encoder):
                Self.makeUnique(&encoder)
                let result = encoder.value.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .structural(encoder)
                return result
            case var .value(encoder):
                Self.makeUnique(&encoder)
                let result = encoder.value.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .value(encoder)
                return result
            case var .redistribution(encoder):
                Self.makeUnique(&encoder)
                let result = encoder.value.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .redistribution(encoder)
                return result
            case var .lockstep(encoder):
                Self.makeUnique(&encoder)
                let result = encoder.value.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .lockstep(encoder)
                return result
            case var .relation(encoder):
                Self.makeUnique(&encoder)
                let result = encoder.value.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .relation(encoder)
                return result
            case var .stagedJoint(encoder):
                Self.makeUnique(&encoder)
                let result = encoder.value.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .stagedJoint(encoder)
                return result
            case var .swap(encoder):
                Self.makeUnique(&encoder)
                let result = encoder.value.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .swap(encoder)
                return result
            case var .windowRemoval(encoder):
                Self.makeUnique(&encoder)
                let result = encoder.value.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .windowRemoval(encoder)
                return result
            case var .reorder(encoder):
                Self.makeUnique(&encoder)
                let result = encoder.value.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .reorder(encoder)
                return result
            case var .laneCollapse(encoder):
                Self.makeUnique(&encoder)
                let result = encoder.value.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .laneCollapse(encoder)
                return result
            case var .depthCollapse(encoder):
                Self.makeUnique(&encoder)
                let result = encoder.value.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .depthCollapse(encoder)
                return result
            case var .binarySearch(encoder):
                Self.makeUnique(&encoder)
                let result = encoder.value.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .binarySearch(encoder)
                return result
            case var .boundValueCovering(encoder):
                Self.makeUnique(&encoder)
                let result = encoder.value.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .boundValueCovering(encoder)
                return result
            case var .liftedStage(encoder):
                Self.makeUnique(&encoder)
                let result = encoder.value.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .liftedStage(encoder)
                return result
            case var .composed(encoder):
                Self.makeUnique(&encoder)
                let result = encoder.value.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .composed(encoder)
                return result
        }
    }

    var hadUnresolvedReplacement: Bool {
        switch self {
            case let .structural(encoder):
                encoder.value.hadUnresolvedReplacement
            case let .value(encoder):
                encoder.value.hadUnresolvedReplacement
            case let .redistribution(encoder):
                encoder.value.hadUnresolvedReplacement
            case let .lockstep(encoder):
                encoder.value.hadUnresolvedReplacement
            case let .relation(encoder):
                encoder.value.hadUnresolvedReplacement
            case let .stagedJoint(encoder):
                encoder.value.hadUnresolvedReplacement
            case let .swap(encoder):
                encoder.value.hadUnresolvedReplacement
            case let .windowRemoval(encoder):
                encoder.value.hadUnresolvedReplacement
            case let .reorder(encoder):
                encoder.value.hadUnresolvedReplacement
            case let .laneCollapse(encoder):
                encoder.value.hadUnresolvedReplacement
            case let .depthCollapse(encoder):
                encoder.value.hadUnresolvedReplacement
            case let .binarySearch(encoder):
                encoder.value.hadUnresolvedReplacement
            case let .boundValueCovering(encoder):
                encoder.value.hadUnresolvedReplacement
            case let .liftedStage(encoder):
                encoder.value.hadUnresolvedReplacement
            case let .composed(encoder):
                encoder.value.hadUnresolvedReplacement
        }
    }

    var convergenceRecords: [Int: ConvergedOrigin] {
        switch self {
            case let .structural(encoder):
                encoder.value.convergenceRecords
            case let .value(encoder):
                encoder.value.convergenceRecords
            case let .redistribution(encoder):
                encoder.value.convergenceRecords
            case let .lockstep(encoder):
                encoder.value.convergenceRecords
            case let .relation(encoder):
                encoder.value.convergenceRecords
            case let .stagedJoint(encoder):
                encoder.value.convergenceRecords
            case let .swap(encoder):
                encoder.value.convergenceRecords
            case let .windowRemoval(encoder):
                encoder.value.convergenceRecords
            case let .reorder(encoder):
                encoder.value.convergenceRecords
            case let .laneCollapse(encoder):
                encoder.value.convergenceRecords
            case let .depthCollapse(encoder):
                encoder.value.convergenceRecords
            case let .binarySearch(encoder):
                encoder.value.convergenceRecords
            case let .boundValueCovering(encoder):
                encoder.value.convergenceRecords
            case let .liftedStage(encoder):
                encoder.value.convergenceRecords
            case let .composed(encoder):
                encoder.value.convergenceRecords
        }
    }

    mutating func flushPartialConvergence() {
        switch consume self {
            case var .structural(encoder):
                Self.makeUnique(&encoder)
                encoder.value.flushPartialConvergence()
                self = .structural(encoder)
            case var .value(encoder):
                Self.makeUnique(&encoder)
                encoder.value.flushPartialConvergence()
                self = .value(encoder)
            case var .redistribution(encoder):
                Self.makeUnique(&encoder)
                encoder.value.flushPartialConvergence()
                self = .redistribution(encoder)
            case var .lockstep(encoder):
                Self.makeUnique(&encoder)
                encoder.value.flushPartialConvergence()
                self = .lockstep(encoder)
            case var .relation(encoder):
                Self.makeUnique(&encoder)
                encoder.value.flushPartialConvergence()
                self = .relation(encoder)
            case var .stagedJoint(encoder):
                Self.makeUnique(&encoder)
                encoder.value.flushPartialConvergence()
                self = .stagedJoint(encoder)
            case var .swap(encoder):
                Self.makeUnique(&encoder)
                encoder.value.flushPartialConvergence()
                self = .swap(encoder)
            case var .windowRemoval(encoder):
                Self.makeUnique(&encoder)
                encoder.value.flushPartialConvergence()
                self = .windowRemoval(encoder)
            case var .reorder(encoder):
                Self.makeUnique(&encoder)
                encoder.value.flushPartialConvergence()
                self = .reorder(encoder)
            case var .laneCollapse(encoder):
                Self.makeUnique(&encoder)
                encoder.value.flushPartialConvergence()
                self = .laneCollapse(encoder)
            case var .depthCollapse(encoder):
                Self.makeUnique(&encoder)
                encoder.value.flushPartialConvergence()
                self = .depthCollapse(encoder)
            case var .binarySearch(encoder):
                Self.makeUnique(&encoder)
                encoder.value.flushPartialConvergence()
                self = .binarySearch(encoder)
            case var .boundValueCovering(encoder):
                Self.makeUnique(&encoder)
                encoder.value.flushPartialConvergence()
                self = .boundValueCovering(encoder)
            case var .liftedStage(encoder):
                Self.makeUnique(&encoder)
                encoder.value.flushPartialConvergence()
                self = .liftedStage(encoder)
            case var .composed(encoder):
                Self.makeUnique(&encoder)
                encoder.value.flushPartialConvergence()
                self = .composed(encoder)
        }
    }

    /// Forces exact decoding for lifted bound-value and exchange probes. False leaves mutation-sensitive selection, including branch materialization, to the scheduler.
    var requiresExactDecoder: Bool {
        switch self {
            case let .composed(encoder):
                encoder.value.requiresExactDecoder
            default:
                false
        }
    }

    var acceptanceHandling: AcceptanceHandling {
        switch self {
            case let .structural(encoder):
                encoder.value.acceptanceHandling
            case let .value(encoder):
                encoder.value.acceptanceHandling
            case let .redistribution(encoder):
                encoder.value.acceptanceHandling
            case let .lockstep(encoder):
                encoder.value.acceptanceHandling
            case let .relation(encoder):
                encoder.value.acceptanceHandling
            case let .stagedJoint(encoder):
                encoder.value.acceptanceHandling
            case let .swap(encoder):
                encoder.value.acceptanceHandling
            case let .windowRemoval(encoder):
                encoder.value.acceptanceHandling
            case let .reorder(encoder):
                encoder.value.acceptanceHandling
            case let .laneCollapse(encoder):
                encoder.value.acceptanceHandling
            case let .depthCollapse(encoder):
                encoder.value.acceptanceHandling
            case let .binarySearch(encoder):
                encoder.value.acceptanceHandling
            case let .boundValueCovering(encoder):
                encoder.value.acceptanceHandling
            case let .liftedStage(encoder):
                encoder.value.acceptanceHandling
            case let .composed(encoder):
                encoder.value.acceptanceHandling
        }
    }

    var admission: DecoderAdmission {
        switch self {
            case let .structural(encoder):
                encoder.value.admission
            case let .value(encoder):
                encoder.value.admission
            case let .redistribution(encoder):
                encoder.value.admission
            case let .lockstep(encoder):
                encoder.value.admission
            case let .relation(encoder):
                encoder.value.admission
            case let .stagedJoint(encoder):
                encoder.value.admission
            case let .swap(encoder):
                encoder.value.admission
            case let .windowRemoval(encoder):
                encoder.value.admission
            case let .reorder(encoder):
                encoder.value.admission
            case let .laneCollapse(encoder):
                encoder.value.admission
            case let .depthCollapse(encoder):
                encoder.value.admission
            case let .binarySearch(encoder):
                encoder.value.admission
            case let .boundValueCovering(encoder):
                encoder.value.admission
            case let .liftedStage(encoder):
                encoder.value.admission
            case let .composed(encoder):
                encoder.value.admission
        }
    }

    /// Constructed stages for bound value and exchange pass reporting. Pivot seeds retain their separate lift-site accounting.
    var composedUpstreamProbesUsed: Int? {
        switch self {
            case let .composed(encoder):
                encoder.value.reportedConstructedStages
            default:
                nil
        }
    }

    /// Generator materializations the encoder ran outside the probe decoder during the current pass, with the site they are reported under; nil for encoders that never materialize. Bound value lifts are counted run-wide by ``BoundValueBuildTally`` instead.
    var liftMaterializations: (site: MaterializationSite, count: Int)? {
        switch self {
            case let .composed(encoder):
                encoder.value.liftMaterializations
            default:
                nil
        }
    }

    /// Discards pre-acceptance lifted scopes on the refresh-and-idle path. No-op for encoders that apply their mutations instead.
    mutating func refreshState(graph: ChoiceGraph, sequence: ChoiceSequence) {
        switch consume self {
            case var .composed(encoder):
                Self.makeUnique(&encoder)
                encoder.value.refreshState(graph: graph, sequence: sequence)
                self = .composed(encoder)
            case var .swap(encoder):
                Self.makeUnique(&encoder)
                encoder.value.refreshState(graph: graph, sequence: sequence)
                self = .swap(encoder)
            case let .structural(encoder):
                self = .structural(encoder)
            case let .value(encoder):
                self = .value(encoder)
            case let .redistribution(encoder):
                self = .redistribution(encoder)
            case let .lockstep(encoder):
                self = .lockstep(encoder)
            case let .relation(encoder):
                self = .relation(encoder)
            case let .stagedJoint(encoder):
                self = .stagedJoint(encoder)
            case let .windowRemoval(encoder):
                self = .windowRemoval(encoder)
            case let .reorder(encoder):
                self = .reorder(encoder)
            case let .laneCollapse(encoder):
                self = .laneCollapse(encoder)
            case let .depthCollapse(encoder):
                self = .depthCollapse(encoder)
            case let .binarySearch(encoder):
                self = .binarySearch(encoder)
            case let .boundValueCovering(encoder):
                self = .boundValueCovering(encoder)
            case let .liftedStage(encoder):
                self = .liftedStage(encoder)
        }
    }

    /// Detaches only genuinely shared encoder state before advancing a dispatch handle.
    private static func makeUnique(_ storage: inout EncoderStorage<some Any>) {
        if isKnownUniquelyReferenced(&storage) == false {
            storage = EncoderStorage(storage.value)
        }
    }
}

/// Retains concrete encoder state between probes; ``EncoderDispatch`` detaches shared storage before mutation.
final class EncoderStorage<Encoder: GraphEncoder> {
    var value: Encoder

    init(_ value: Encoder) {
        self.value = value
    }
}
