/// Routes ``GraphEncoder`` calls to concrete encoder types via enum dispatch, avoiding existential witness-table overhead on the reducer's per-probe hot path.
indirect enum EncoderDispatch {
    case structural(GraphStructuralEncoder)
    case value(GraphValueEncoder)
    case redistribution(GraphRedistributionEncoder)
    case lockstep(GraphLockstepEncoder)
    case relation(GraphRelationEncoder)
    case swap(GraphSwapEncoder)
    case windowRemoval(GraphWindowRemovalEncoder)
    case reorder(GraphReorderEncoder)
    case laneCollapse(GraphLaneCollapseEncoder)
    case depthCollapse(GraphDepthCollapseEncoder)
    case binarySearch(GraphBinarySearchEncoder)
    case boundValueCovering(GraphBoundValueCoveringEncoder)
    case liftedStage(GraphLiftedStageEncoder)
    case composed(GraphComposedEncoder)
}

extension EncoderDispatch: GraphEncoder {
    var name: EncoderName {
        switch self {
            case let .structural(encoder): encoder.name
            case let .value(encoder): encoder.name
            case let .redistribution(encoder): encoder.name
            case let .lockstep(encoder): encoder.name
            case let .relation(encoder): encoder.name
            case let .swap(encoder): encoder.name
            case let .windowRemoval(encoder): encoder.name
            case let .reorder(encoder): encoder.name
            case let .laneCollapse(encoder): encoder.name
            case let .depthCollapse(encoder): encoder.name
            case let .binarySearch(encoder): encoder.name
            case let .boundValueCovering(encoder): encoder.name
            case let .liftedStage(encoder):
                encoder.name
            case let .composed(encoder): encoder.name
        }
    }

    mutating func start(scope: EncoderInput) {
        switch self {
            case var .structural(encoder):
                encoder.start(scope: scope)
                self = .structural(encoder)
            case var .value(encoder):
                encoder.start(scope: scope)
                self = .value(encoder)
            case var .redistribution(encoder):
                encoder.start(scope: scope)
                self = .redistribution(encoder)
            case var .lockstep(encoder):
                encoder.start(scope: scope)
                self = .lockstep(encoder)
            case var .relation(encoder):
                encoder.start(scope: scope)
                self = .relation(encoder)
            case var .swap(encoder):
                encoder.start(scope: scope)
                self = .swap(encoder)
            case var .windowRemoval(encoder):
                encoder.start(scope: scope)
                self = .windowRemoval(encoder)
            case var .reorder(encoder):
                encoder.start(scope: scope)
                self = .reorder(encoder)
            case var .laneCollapse(encoder):
                encoder.start(scope: scope)
                self = .laneCollapse(encoder)
            case var .depthCollapse(encoder):
                encoder.start(scope: scope)
                self = .depthCollapse(encoder)
            case var .binarySearch(encoder):
                encoder.start(scope: scope)
                self = .binarySearch(encoder)
            case var .boundValueCovering(encoder):
                encoder.start(scope: scope)
                self = .boundValueCovering(encoder)
            case var .liftedStage(encoder):
                encoder.start(scope: scope)
                self = .liftedStage(encoder)
            case var .composed(encoder):
                encoder.start(scope: scope)
                self = .composed(encoder)
        }
    }

    mutating func nextProbe(into candidate: inout ChoiceSequence, lastAccepted: Bool) -> EncoderProbe? {
        switch self {
            case var .structural(encoder):
                let result = encoder.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .structural(encoder)
                return result
            case var .value(encoder):
                let result = encoder.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .value(encoder)
                return result
            case var .redistribution(encoder):
                let result = encoder.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .redistribution(encoder)
                return result
            case var .lockstep(encoder):
                let result = encoder.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .lockstep(encoder)
                return result
            case var .relation(encoder):
                let result = encoder.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .relation(encoder)
                return result
            case var .swap(encoder):
                let result = encoder.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .swap(encoder)
                return result
            case var .windowRemoval(encoder):
                let result = encoder.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .windowRemoval(encoder)
                return result
            case var .reorder(encoder):
                let result = encoder.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .reorder(encoder)
                return result
            case var .laneCollapse(encoder):
                let result = encoder.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .laneCollapse(encoder)
                return result
            case var .depthCollapse(encoder):
                let result = encoder.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .depthCollapse(encoder)
                return result
            case var .binarySearch(encoder):
                let result = encoder.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .binarySearch(encoder)
                return result
            case var .boundValueCovering(encoder):
                let result = encoder.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .boundValueCovering(encoder)
                return result
            case var .liftedStage(encoder):
                let result = encoder.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .liftedStage(encoder)
                return result
            case var .composed(encoder):
                let result = encoder.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .composed(encoder)
                return result
        }
    }

    var hadUnresolvedReplacement: Bool {
        switch self {
            case let .structural(encoder): encoder.hadUnresolvedReplacement
            case let .value(encoder): encoder.hadUnresolvedReplacement
            case let .redistribution(encoder): encoder.hadUnresolvedReplacement
            case let .lockstep(encoder): encoder.hadUnresolvedReplacement
            case let .relation(encoder): encoder.hadUnresolvedReplacement
            case let .swap(encoder): encoder.hadUnresolvedReplacement
            case let .windowRemoval(encoder): encoder.hadUnresolvedReplacement
            case let .reorder(encoder): encoder.hadUnresolvedReplacement
            case let .laneCollapse(encoder): encoder.hadUnresolvedReplacement
            case let .depthCollapse(encoder): encoder.hadUnresolvedReplacement
            case let .binarySearch(encoder): encoder.hadUnresolvedReplacement
            case let .boundValueCovering(encoder): encoder.hadUnresolvedReplacement
            case let .liftedStage(encoder):
                encoder.hadUnresolvedReplacement
            case let .composed(encoder): encoder.hadUnresolvedReplacement
        }
    }

    var convergenceRecords: [Int: ConvergedOrigin] {
        switch self {
            case let .structural(encoder): encoder.convergenceRecords
            case let .value(encoder): encoder.convergenceRecords
            case let .redistribution(encoder): encoder.convergenceRecords
            case let .lockstep(encoder): encoder.convergenceRecords
            case let .relation(encoder): encoder.convergenceRecords
            case let .swap(encoder): encoder.convergenceRecords
            case let .windowRemoval(encoder): encoder.convergenceRecords
            case let .reorder(encoder): encoder.convergenceRecords
            case let .laneCollapse(encoder): encoder.convergenceRecords
            case let .depthCollapse(encoder): encoder.convergenceRecords
            case let .binarySearch(encoder): encoder.convergenceRecords
            case let .boundValueCovering(encoder): encoder.convergenceRecords
            case let .liftedStage(encoder):
                encoder.convergenceRecords
            case let .composed(encoder): encoder.convergenceRecords
        }
    }

    mutating func flushPartialConvergence() {
        switch self {
            case var .structural(encoder):
                encoder.flushPartialConvergence()
                self = .structural(encoder)
            case var .value(encoder):
                encoder.flushPartialConvergence()
                self = .value(encoder)
            case var .redistribution(encoder):
                encoder.flushPartialConvergence()
                self = .redistribution(encoder)
            case var .lockstep(encoder):
                encoder.flushPartialConvergence()
                self = .lockstep(encoder)
            case var .relation(encoder):
                encoder.flushPartialConvergence()
                self = .relation(encoder)
            case var .swap(encoder):
                encoder.flushPartialConvergence()
                self = .swap(encoder)
            case var .windowRemoval(encoder):
                encoder.flushPartialConvergence()
                self = .windowRemoval(encoder)
            case var .reorder(encoder):
                encoder.flushPartialConvergence()
                self = .reorder(encoder)
            case var .laneCollapse(encoder):
                encoder.flushPartialConvergence()
                self = .laneCollapse(encoder)
            case var .depthCollapse(encoder):
                encoder.flushPartialConvergence()
                self = .depthCollapse(encoder)
            case var .binarySearch(encoder):
                encoder.flushPartialConvergence()
                self = .binarySearch(encoder)
            case var .boundValueCovering(encoder):
                encoder.flushPartialConvergence()
                self = .boundValueCovering(encoder)
            case var .liftedStage(encoder):
                encoder.flushPartialConvergence()
                self = .liftedStage(encoder)
            case var .composed(encoder):
                encoder.flushPartialConvergence()
                self = .composed(encoder)
        }
    }

    /// Forces exact decoding for lifted bound-value and exchange probes. False leaves mutation-sensitive selection, including branch materialization, to the scheduler.
    var requiresExactDecoder: Bool {
        switch self {
            case let .composed(encoder):
                encoder.requiresExactDecoder
            default:
                false
        }
    }

    /// Discards lifted searches after acceptance without applying their mutations to the dispatched graph. Window removal and sibling swap also skip mutation application so their sessions survive acceptance: the window removal stepper keeps growing the window, and the swap extension keeps pushing content rightward. Other encoders retain mutation application and finish when it requires a rebuild.
    var acceptanceHandling: AcceptanceHandling {
        switch self {
            case let .composed(encoder):
                encoder.acceptanceHandling
            case .windowRemoval, .swap:
                .refreshAndIdle
            default:
                .applyMutation
        }
    }

    /// Constructed stages for bound value and exchange pass reporting. Pivot seeds retain their separate lift-site accounting.
    var composedUpstreamProbesUsed: Int? {
        switch self {
            case let .composed(encoder):
                encoder.reportedConstructedStages
            default:
                nil
        }
    }

    /// Generator materializations the encoder ran outside the probe decoder during the current pass, with the site they are reported under; nil for encoders that never materialize. Bound value lifts are counted run-wide by ``BoundValueBuildTally`` instead.
    var liftMaterializations: (site: MaterializationSite, count: Int)? {
        switch self {
            case let .composed(encoder):
                encoder.liftMaterializations
            default:
                nil
        }
    }

    /// Discards pre-acceptance lifted scopes on the refresh-and-idle path. No-op for encoders that apply their mutations instead.
    mutating func refreshState(graph: ChoiceGraph, sequence: ChoiceSequence) {
        switch self {
            case var .composed(encoder):
                encoder.refreshState(graph: graph, sequence: sequence)
                self = .composed(encoder)
            case var .swap(encoder):
                encoder.refreshState(graph: graph, sequence: sequence)
                self = .swap(encoder)
            default:
                break
        }
    }
}
