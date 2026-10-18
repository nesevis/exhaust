/// Attributes floor motion to a bounded recent history of numeric changes. Edges are ranking hints, not causal proof; ambiguous windows retain several possible partners and motion without prior history supplies no edge.
struct CouplingTracker {
    static let maximumHistory = 32
    static let maximumNodes = 256
    static let maximumEdges = 256

    private struct Change {
        let pass: Int
        let nodes: [Int]
    }

    private var history: [Change] = []
    private var convergencePasses: [Int: Int] = [:]
    private var edgeCount = 0

    /// Runs independently of research diagnostics and adds no property probes. Node IDs are discarded when graph structure or numbering changes.
    mutating func observe(
        motionNodes: Set<Int>,
        convergedNodes: [Int],
        changedNodes: Set<Int>,
        pass: Int,
        graph: inout ChoiceGraph
    ) {
        for motionNode in motionNodes.sorted() where isNumeric(motionNode, graph: graph) {
            guard edgeCount < Self.maximumEdges else { break }
            guard let sincePass = convergencePasses[motionNode] else { continue }
            for change in history where change.pass > sincePass {
                for partner in change.nodes where partner != motionNode {
                    guard edgeCount < Self.maximumEdges else { break }
                    guard graph.couplingDependents[partner]?.contains(motionNode) != true else { continue }
                    graph.couplingDependents[partner, default: []].insert(motionNode)
                    edgeCount += 1
                }
            }
        }
        for nodeID in convergedNodes.sorted() where isNumeric(nodeID, graph: graph) {
            if convergencePasses[nodeID] != nil || convergencePasses.count < Self.maximumNodes {
                convergencePasses[nodeID] = pass
            }
        }
        let numericChanges = changedNodes.sorted().filter { isNumeric($0, graph: graph) }.prefix(Self.maximumNodes)
        if numericChanges.isEmpty == false {
            history.append(Change(pass: pass, nodes: Array(numericChanges)))
            if history.count > Self.maximumHistory { history.removeFirst() }
        }
    }

    private func isNumeric(_ nodeID: Int, graph: ChoiceGraph) -> Bool {
        guard graph.nodes.indices.contains(nodeID),
              case let .chooseBits(metadata) = graph.nodes[nodeID].kind
        else { return false }
        return NumericPairQuery.isNumeric(metadata)
    }
}
