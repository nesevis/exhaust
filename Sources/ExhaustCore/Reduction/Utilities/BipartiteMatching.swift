//
//  BipartiteMatching.swift
//  Exhaust
//

// MARK: - Academic Background

//
// Maximum antichain via Dilworth's theorem (Dilworth, "A Decomposition Theorem for Partially Ordered Sets", Annals of Mathematics, 1950): maximum antichain = n - maximum matching on the reachability bipartite graph. The reduction to bipartite matching follows Mirsky (American Mathematical Monthly, 1971). Matching uses Hopcroft-Karp, O(E sqrt(V)).

// MARK: - Bipartite Matching

/// Hopcroft-Karp maximum bipartite matching algorithm.
///
/// Finds the maximum cardinality matching in a bipartite graph with left nodes `0 ..< leftCount` and right nodes `0 ..< rightCount`. Edges connect left nodes to right nodes.
///
/// Used by ``ChoiceGraph`` for optimal antichain computation via Dilworth's theorem: the maximum antichain in a finite poset equals the number of elements minus the maximum matching on the reachability bipartite graph.
///
/// - Complexity: O(*E* . sqrt(*V*)), where *E* is the edge count and *V* is the total node count.
enum BipartiteMatching {
    /// Computes the maximum cardinality matching.
    ///
    /// - Parameters:
    ///   - leftCount: Number of left-side nodes (indexed `0 ..< leftCount`).
    ///   - rightCount: Number of right-side nodes (indexed `0 ..< rightCount`).
    ///   - adjacency: For each left node, the list of right nodes it connects to.
    /// - Returns: The matching as an array indexed by left node, where each entry is the matched right node or `nil` if unmatched.
    static func hopcroftKarp(
        leftCount: Int,
        rightCount: Int,
        adjacency: [[Int]]
    ) -> [Int?] {
        precondition(adjacency.count == leftCount)

        let sentinel = leftCount + rightCount + 1
        var matchLeft = [Int?](repeating: nil, count: leftCount)
        var matchRight = [Int?](repeating: nil, count: rightCount)
        var distance = [Int](repeating: 0, count: leftCount + 1)

        // BFS: find shortest augmenting path layers from all free left nodes simultaneously.
        func bfs() -> Bool {
            var queue: [Int] = []
            for left in 0 ..< leftCount {
                if matchLeft[left] == nil {
                    distance[left] = 0
                    queue.append(left)
                } else {
                    distance[left] = sentinel
                }
            }
            // distance[leftCount] represents the sentinel (nil-matched) distance.
            distance[leftCount] = sentinel

            var head = 0
            while head < queue.count {
                let left = queue[head]
                head += 1
                guard distance[left] < distance[leftCount] else { continue }
                for right in adjacency[left] {
                    // The right node's match (or leftCount as sentinel for free right nodes).
                    let nextLeft = matchRight[right] ?? leftCount
                    if distance[nextLeft] == sentinel {
                        distance[nextLeft] = distance[left] + 1
                        if nextLeft != leftCount {
                            queue.append(nextLeft)
                        }
                    }
                }
            }
            return distance[leftCount] != sentinel
        }

        // DFS: find an augmenting path from a free left node along the BFS layers.
        func dfs(_ left: Int) -> Bool {
            guard left != leftCount else { return true }
            for right in adjacency[left] {
                let nextLeft = matchRight[right] ?? leftCount
                if distance[nextLeft] == distance[left] + 1 {
                    if dfs(nextLeft) {
                        matchRight[right] = left
                        matchLeft[left] = right
                        return true
                    }
                }
            }
            distance[left] = sentinel
            return false
        }

        // Main loop: repeat BFS + DFS until no more augmenting paths exist.
        while bfs() {
            for left in 0 ..< leftCount where matchLeft[left] == nil {
                _ = dfs(left)
            }
        }

        return matchLeft
    }

    /// Computes the maximum matching size.
    static func maximumMatchingSize(
        leftCount: Int,
        rightCount: Int,
        adjacency: [[Int]]
    ) -> Int {
        let matching = hopcroftKarp(
            leftCount: leftCount,
            rightCount: rightCount,
            adjacency: adjacency
        )
        return matching.count(where: { $0 != nil })
    }

    // MARK: - Minimum Vertex Cover (Konig's Theorem)

    /// Computes the minimum vertex cover from a maximum matching.
    ///
    /// By Konig's theorem, the minimum vertex cover in a bipartite graph equals the maximum matching size. The cover itself is computed by alternating reachability from free (unmatched) left nodes.
    ///
    /// - Parameters:
    ///   - leftCount: Number of left-side nodes.
    ///   - rightCount: Number of right-side nodes.
    ///   - adjacency: For each left node, the list of right nodes it connects to.
    ///   - matching: The maximum matching (from ``hopcroftKarp(leftCount:rightCount:adjacency:)``).
    /// - Returns: A tuple of sets: left-side nodes in the cover and right-side nodes in the cover.
    static func minimumVertexCover(
        leftCount: Int,
        rightCount: Int,
        adjacency: [[Int]],
        matching: [Int?]
    ) -> (leftCover: Set<Int>, rightCover: Set<Int>) {
        // Build reverse matching: right node → matched left node.
        var matchRight = [Int?](repeating: nil, count: rightCount)
        for (left, right) in matching.enumerated() {
            if let right {
                matchRight[right] = left
            }
        }

        // Find all left nodes reachable from free left nodes via alternating paths.
        // An alternating path: free left → (unmatched edge) → right → (matched edge) → left → ...
        var visitedLeft = Set<Int>()
        var visitedRight = Set<Int>()
        var stack: [Int] = []

        // Start from all free (unmatched) left nodes.
        for left in 0 ..< leftCount where matching[left] == nil {
            stack.append(left)
            visitedLeft.insert(left)
        }

        while stack.isEmpty == false {
            let left = stack.removeLast()
            for right in adjacency[left] {
                guard visitedRight.contains(right) == false else { continue }
                visitedRight.insert(right)
                // Follow the matched edge back to a left node.
                if let matchedLeft = matchRight[right], visitedLeft.contains(matchedLeft) == false {
                    visitedLeft.insert(matchedLeft)
                    stack.append(matchedLeft)
                }
            }
        }

        // Konig's theorem: minimum vertex cover = left nodes NOT in the alternating-reachable set (matched left nodes not reachable)
        //   + right nodes IN the alternating-reachable set
        var leftCover = Set<Int>()
        for left in 0 ..< leftCount where visitedLeft.contains(left) == false {
            leftCover.insert(left)
        }
        let rightCover = visitedRight

        return (leftCover, rightCover)
    }

    // MARK: - Maximum Antichain (Dilworth's Theorem)

    /// Computes the maximum antichain of a DAG using Dilworth's theorem.
    ///
    /// The maximum antichain equals the set of nodes not in the minimum vertex cover of the reachability bipartite graph. Specifically:
    /// 1. Build a bipartite graph where left and right sides are both copies of the DAG's nodes.
    /// 2. Add edge (u, v) if u is reachable from v (u < v in the partial order).
    /// 3. Find the maximum matching via Hopcroft-Karp.
    /// 4. Find the minimum vertex cover via Konig's theorem.
    /// 5. The antichain is the set of nodes appearing in neither the left cover nor the right cover.
    ///
    /// - Parameters:
    ///   - nodeCount: Number of nodes in the DAG.
    ///   - reachability: For each node, the set of nodes reachable from it (strict — excludes self).
    /// - Returns: The node indices forming the maximum antichain.
    static func maximumAntichain(
        nodeCount: Int,
        reachability: [Int: Set<Int>]
    ) -> [Int] {
        // Build the bipartite adjacency: left node u has edge to right node v if u < v.
        // Sort each adjacency list to ensure deterministic matching across runs (Set iteration order is non-deterministic in Swift).
        var adjacency = [[Int]](repeating: [], count: nodeCount)
        for source in 0 ..< nodeCount {
            guard let reachable = reachability[source] else { continue }
            adjacency[source] = reachable.sorted()
        }

        let matching = hopcroftKarp(
            leftCount: nodeCount,
            rightCount: nodeCount,
            adjacency: adjacency
        )

        let (leftCover, rightCover) = minimumVertexCover(
            leftCount: nodeCount,
            rightCount: nodeCount,
            adjacency: adjacency,
            matching: matching
        )

        // Antichain = nodes not in either side of the cover.
        var antichain: [Int] = []
        for node in 0 ..< nodeCount {
            if leftCover.contains(node) == false, rightCover.contains(node) == false {
                antichain.append(node)
            }
        }
        return antichain
    }
}
