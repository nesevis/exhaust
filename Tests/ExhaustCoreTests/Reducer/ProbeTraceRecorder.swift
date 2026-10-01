@testable import ExhaustCore

/// Stores full choice entries rather than cache hashes, so metadata changes remain visible in characterisation fixtures.
final class ProbeTraceRecorder {
    enum Event: Equatable {
        case emitted(Int, [ChoiceSequenceValue], Mutation)
        case decoderSelected(Int, preferExact: Bool, materializePicks: Bool)
        case decoded(Int, [ChoiceSequenceValue])
        case terminated(Int, ProbeDisposition, materializationAttempts: Int)
    }

    struct Leaf: Equatable {
        let nodeID: Int
        let value: ChoiceValue
        let mayReshape: Bool
    }

    struct Removal: Equatable {
        let sequenceNodeID: Int
        let removedNodeIDs: [Int]
    }

    enum Mutation: Equatable {
        case leafValues([Leaf])
        case sequenceElementsRemoved([Removal])
        case branchSelected(Int, UInt64)
        case selfSimilarReplaced(Int, Int)
        case descendantPromoted(Int, Int)
        case sequenceElementsMigrated(Int, Int, [Int], Int)
        case siblingsSwapped(Int, Int, Int)
        case sequenceReordered

        init(_ mutation: ProjectedMutation) {
            self = switch mutation {
                case let .leafValues(changes):
                    .leafValues(changes.map {
                        Leaf(nodeID: $0.leafNodeID, value: $0.newValue, mayReshape: $0.mayReshape)
                    })
                case let .sequenceElementsRemoved(removals):
                    .sequenceElementsRemoved(removals.map {
                        Removal(sequenceNodeID: $0.seqNodeID, removedNodeIDs: $0.removedNodeIDs)
                    })
                case let .branchSelected(nodeID, selectedID):
                    .branchSelected(nodeID, selectedID)
                case let .selfSimilarReplaced(target, donor):
                    .selfSimilarReplaced(target, donor)
                case let .descendantPromoted(ancestor, descendant):
                    .descendantPromoted(ancestor, descendant)
                case let .sequenceElementsMigrated(source, receiver, moved, offset):
                    .sequenceElementsMigrated(source, receiver, moved, offset)
                case let .siblingsSwapped(parent, first, second):
                    .siblingsSwapped(parent, first, second)
                case .sequenceReordered:
                    .sequenceReordered
            }
        }
    }

    private(set) var events: [Event] = []

    func record(_ observation: ProbeObservation) {
        let event: Event = switch observation {
            case let .emitted(probeID, sequence, mutation):
                .emitted(probeID, Array(sequence), Mutation(mutation))
            case let .decoderSelected(probeID, preferExact, materializePicks):
                .decoderSelected(probeID, preferExact: preferExact, materializePicks: materializePicks)
            case let .decoded(probeID, sequence):
                .decoded(probeID, Array(sequence))
            case let .terminated(probeID, disposition, attempts):
                .terminated(probeID, disposition, materializationAttempts: attempts)
        }
        events.append(event)
    }
}
