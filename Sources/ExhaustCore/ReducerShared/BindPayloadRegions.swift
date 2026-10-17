// MARK: - Bind Payload Regions

/// Separates terminal value work by its nearest upstream bind.
struct BindPayloadRegions {
    private let regionByNode: [Int?]

    /// Resolves regions in allocation order so each child inherits an already-resolved parent region.
    init(graph: ChoiceGraph) {
        var regions = [Int?](repeating: nil, count: graph.nodes.count)
        for node in graph.nodes {
            guard let parentID = node.parent else {
                continue
            }
            let parent = graph.nodes[parentID]
            regions[node.id] = switch parent.kind {
                case let .bind(metadata) where parent.children.count > metadata.boundChildIndex
                && parent.children[metadata.boundChildIndex] == node.id:
                    parentID
                default:
                    regions[parentID]
            }
        }
        regionByNode = regions
    }

    /// Truly independent leaves stay together; separate bound regions get separate scopes.
    func group(_ leaves: [LeafEntry]) -> [[LeafEntry]] {
        let groups = Dictionary(grouping: leaves) { regionByNode[$0.nodeID] ?? -1 }
        return groups.sorted { $0.key < $1.key }.map(\.value)
    }
}
