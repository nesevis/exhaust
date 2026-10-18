/// Shares dependency reachability between the live graph and cursors retaining only immutable topology.
///
/// Keeping adjacency separate from mutable graph nodes lets structural cursors survive value-only changes without retaining the node array and forcing copy-on-write on every acceptance.
enum DependencyReachability {
    /// Searches for a path of one or more edges, stopping as soon as the target is found.
    ///
    /// - Complexity: O(V + E) in the visited dependency subgraph.
    static func isReachable(from source: Int, to target: Int, adjacency: [[Int]]) -> Bool {
        guard source >= 0, target >= 0, source < adjacency.count, target < adjacency.count else {
            return false
        }
        var visited: Set<Int> = []
        var stack = [source]
        while let current = stack.popLast() {
            guard visited.insert(current).inserted else {
                continue
            }
            for neighbor in adjacency[current] {
                if neighbor == target {
                    return true
                }
                stack.append(neighbor)
            }
        }
        return false
    }

    /// Finds candidate nodes reachable from the source while excluding the source itself, even when dependency edges form a cycle.
    ///
    /// Dependency caches use one traversal per source to discover candidate relationships without computing a full transitive closure.
    ///
    /// - Complexity: O(V + E) in the visited dependency subgraph.
    static func reachableNodes(from source: Int, within candidates: Set<Int>, adjacency: [[Int]]) -> Set<Int> {
        guard source >= 0, source < adjacency.count else {
            return []
        }
        var visited: Set<Int> = []
        var result: Set<Int> = []
        var stack = [source]
        while let current = stack.popLast() {
            guard visited.insert(current).inserted else {
                continue
            }
            if current != source, candidates.contains(current) {
                result.insert(current)
            }
            for neighbor in adjacency[current] {
                stack.append(neighbor)
            }
        }
        return result
    }
}
