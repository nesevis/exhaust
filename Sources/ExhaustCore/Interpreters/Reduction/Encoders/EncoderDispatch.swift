/// Routes ``GraphEncoder`` calls to concrete encoder types via enum dispatch, avoiding existential witness-table overhead on the reducer's per-probe hot path.
indirect enum EncoderDispatch {
    case structural(GraphStructuralEncoder)
    case value(GraphValueEncoder)
    case redistribution(GraphRedistributionEncoder)
    case lockstep(GraphLockstepEncoder)
    case relation(GraphRelationEncoder)
    case swap(GraphSwapEncoder)
    case reorder(GraphReorderEncoder)
    case laneCollapse(GraphLaneCollapseEncoder)
    case binarySearch(GraphBinarySearchEncoder)
    case boundValueCovering(GraphBoundValueCoveringEncoder)
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
            case let .reorder(encoder): encoder.name
            case let .laneCollapse(encoder): encoder.name
            case let .binarySearch(encoder): encoder.name
            case let .boundValueCovering(encoder): encoder.name
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
            case var .reorder(encoder):
                encoder.start(scope: scope)
                self = .reorder(encoder)
            case var .laneCollapse(encoder):
                encoder.start(scope: scope)
                self = .laneCollapse(encoder)
            case var .binarySearch(encoder):
                encoder.start(scope: scope)
                self = .binarySearch(encoder)
            case var .boundValueCovering(encoder):
                encoder.start(scope: scope)
                self = .boundValueCovering(encoder)
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
            case var .reorder(encoder):
                let result = encoder.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .reorder(encoder)
                return result
            case var .laneCollapse(encoder):
                let result = encoder.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .laneCollapse(encoder)
                return result
            case var .binarySearch(encoder):
                let result = encoder.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .binarySearch(encoder)
                return result
            case var .boundValueCovering(encoder):
                let result = encoder.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .boundValueCovering(encoder)
                return result
            case var .composed(encoder):
                let result = encoder.nextProbe(into: &candidate, lastAccepted: lastAccepted)
                self = .composed(encoder)
                return result
        }
    }

    var hadReplacementShortlexRejection: Bool {
        switch self {
            case let .structural(encoder): encoder.hadReplacementShortlexRejection
            case let .value(encoder): encoder.hadReplacementShortlexRejection
            case let .redistribution(encoder): encoder.hadReplacementShortlexRejection
            case let .lockstep(encoder): encoder.hadReplacementShortlexRejection
            case let .relation(encoder): encoder.hadReplacementShortlexRejection
            case let .swap(encoder): encoder.hadReplacementShortlexRejection
            case let .reorder(encoder): encoder.hadReplacementShortlexRejection
            case let .laneCollapse(encoder): encoder.hadReplacementShortlexRejection
            case let .binarySearch(encoder): encoder.hadReplacementShortlexRejection
            case let .boundValueCovering(encoder): encoder.hadReplacementShortlexRejection
            case let .composed(encoder): encoder.hadReplacementShortlexRejection
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
            case let .reorder(encoder): encoder.convergenceRecords
            case let .laneCollapse(encoder): encoder.convergenceRecords
            case let .binarySearch(encoder): encoder.convergenceRecords
            case let .boundValueCovering(encoder): encoder.convergenceRecords
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
            case var .reorder(encoder):
                encoder.flushPartialConvergence()
                self = .reorder(encoder)
            case var .laneCollapse(encoder):
                encoder.flushPartialConvergence()
                self = .laneCollapse(encoder)
            case var .binarySearch(encoder):
                encoder.flushPartialConvergence()
                self = .binarySearch(encoder)
            case var .boundValueCovering(encoder):
                encoder.flushPartialConvergence()
                self = .boundValueCovering(encoder)
            case var .composed(encoder):
                encoder.flushPartialConvergence()
                self = .composed(encoder)
        }
    }

    /// Returns true for encoders whose probes alter the bound subtree, requiring a full graph rebuild and ``refreshState(graph:sequence:)`` call after each acceptance. Currently only the ``GraphComposedEncoder`` case.
    var isStateful: Bool {
        if case .composed = self { return true }
        return false
    }

    /// Re-derives cached scope state from the live graph after a structural mutation. No-op for non-stateful encoders.
    mutating func refreshState(graph: ChoiceGraph, sequence: ChoiceSequence) {
        guard case var .composed(encoder) = self else { return }
        encoder.refreshState(graph: graph, sequence: sequence)
        self = .composed(encoder)
    }
}
