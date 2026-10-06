/// Answers strict descendant queries without walking parent chains for every candidate pair.
///
/// Preorder intervals follow the parent links, which are authoritative for the prior descendant predicate. The forest includes inactive nodes and does not rely on flattened sequence ranges or node-ID order. Parent links must form an acyclic forest with valid node IDs.
///
/// - Complexity: O(V) preparation and retained storage, followed by O(1) queries.
struct ContainmentIndex {
    private struct Visit {
        let nodeID: Int
        let isExit: Bool
    }

    private let preorder: [Int]
    private let subtreeEnd: [Int]

    /// Builds intervals iteratively so deep containment chains do not consume the call stack.
    init(parentNodeIDs: [Int?]) {
        var children = [[Int]](repeating: [], count: parentNodeIDs.count)
        var roots: [Int] = []
        for (nodeID, parent) in parentNodeIDs.enumerated() {
            guard let parent else {
                roots.append(nodeID)
                continue
            }
            precondition(parent >= 0 && parent < parentNodeIDs.count, "Containment parents must address valid nodes")
            children[parent].append(nodeID)
        }
        var starts = [Int](repeating: -1, count: parentNodeIDs.count)
        var ends = [Int](repeating: -1, count: parentNodeIDs.count)
        var position = 0
        for root in roots {
            var stack = [Visit(nodeID: root, isExit: false)]
            while let visit = stack.popLast() {
                if visit.isExit {
                    ends[visit.nodeID] = position
                    continue
                }
                starts[visit.nodeID] = position
                position += 1
                stack.append(Visit(nodeID: visit.nodeID, isExit: true))
                for child in children[visit.nodeID].reversed() {
                    stack.append(Visit(nodeID: child, isExit: false))
                }
            }
        }
        precondition(position == parentNodeIDs.count, "Containment parents must form an acyclic forest")
        preorder = starts
        subtreeEnd = ends
    }

    /// Excludes the ancestor itself and nodes from other roots, even when their sequence spans happen to overlap.
    func isDescendant(_ nodeID: Int, of ancestorNodeID: Int) -> Bool {
        guard nodeID >= 0, ancestorNodeID >= 0,
              nodeID < preorder.count, ancestorNodeID < preorder.count
        else {
            return false
        }
        return preorder[nodeID] > preorder[ancestorNodeID] && preorder[nodeID] < subtreeEnd[ancestorNodeID]
    }
}
